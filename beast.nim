import selectors, net, nativesockets, os, httpcore, asyncdispatch, strutils

from osproc import countProcessors

import times # TODO this shouldn't be required. Nim bug?

export httpcore.HttpMethod

type
  Data = object
    isServer: bool ## Determines whether FD is the server listening socket.
    ## A queue of data that needs to be sent when the FD becomes writeable.
    sendQueue: string
    ## The number of characters in `sendQueue` that have been sent already.
    bytesSent: int
    ## Big chunk of data read from client during request.
    data: string
    ## Determines whether `data` contains "\c\l\c\l"
    headersFinished: bool

type
  Request* = object
    selector: Selector[Data]
    client: SocketHandle

  OnRequest* = proc (req: Request) {.gcsafe.}

proc initData(isServer: bool): Data =
  Data(isServer: isServer,
       sendQueue: "",
       bytesSent: 0,
       data: "",
       headersFinished: false
      )

template handleAccept() =
  let (client, address) = fd.SocketHandle.accept()
  if client == osInvalidSocket:
    let lastError = osLastError()
    raiseOSError(lastError)
  setBlocking(client, false)
  selector.registerHandle(client, {Event.Read},
                          initData(false))

template handleClientClosure(selector: Selector[Data],
                             fd: SocketHandle|int,
                             doBreak=true) =
  # TODO: Logging that the socket was closed.
  selector.unregister(fd)
  fd.SocketHandle.close()
  when doBreak:
    break

proc processEvents(selector: Selector[Data],
                   events: array[64, ReadyKey], count: int,
                   onRequest: OnRequest) =
  for i in 0 .. <count:
    let fd = events[i].fd
    template data: var Data = selector.getData(fd)
    if data.isServer:
      if Event.Read in events[i].events:
        handleAccept()
      else:
        assert false, "Only Read events are expected for the server"
    else:
      if Event.Read in events[i].events:
        assert data.sendQueue.len == 0
        const size = 256
        var buf: array[size, char]
        # Read until EAGAIN. Hacky, but should work :)
        while true:
          let ret = recv(fd.SocketHandle, addr buf[0], size, 0.cint)
          if ret == 0:
            handleClientClosure(selector, fd)

          if ret == -1:
            # Error!
            let lastError = osLastError()
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
              break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              handleClientClosure(selector, fd)
            raiseOSError(lastError)

          # Write buffer to our data.
          data.data.add(addr(buf[0]))

          if buf[ret-1] == '\l' and buf[ret-2] == '\c':
            # First line and headers for request received.
            # TODO: For now we only support GET requests.
            # TODO: Check for POST and Content-Length in the most
            # TODO: optimised way possible!
            data.headersFinished = true
            assert data.sendQueue.len == 0
            onRequest(Request(selector: selector, client: fd.SocketHandle))

          if ret != size:
            # Assume there is nothing else for us and break.
            break
      elif Event.Write in events[i].events:
        assert data.sendQueue.len > 0
        assert data.bytesSent < data.sendQueue.len
        # Write the sendQueue.
        let leftover = data.sendQueue.len-data.bytesSent
        let ret = send(fd.SocketHandle, addr data.sendQueue[data.bytesSent],
                       leftover, 0)
        if ret == -1:
          # Error!
          let lastError = osLastError()
          if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
            break
          if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
            handleClientClosure(selector, fd)
          raiseOSError(lastError)

        data.bytesSent.inc(ret)

        if data.sendQueue.len == data.bytesSent:
          data.bytesSent = 0
          data.sendQueue.setLen(0)
          selector.updateHandle(fd.SocketHandle,
                                {Event.Read})
      else:
        assert false

proc eventLoop(onRequest: OnRequest) =
  let selector = newSelector[Data]()

  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(Port(8080))
  server.listen()
  server.getFd().setBlocking(false)
  selector.registerHandle(server.getFd(), {Event.Read}, initData(true))

  var events: array[64, ReadyKey]
  while true:
    let ret = selector.selectInto(-1, events)
    processEvents(selector, events, ret, onRequest)

#[ API start ]#

proc reqMethod*(req: Request): HttpMethod =
  ## Parses the request's data to find the HttpMethod.
  let fdData = req.selector.getData(req.client)
  # fdData.

proc send*(req: Request, body: string) =
  template getData: var Data = req.selector.getData(req.client)
  assert getData.headersFinished

  var
    text = "HTTP/1.1 200 OK\c\LContent-Length: $1\c\L\c\L$2" %
           [$body.len, body]

  if getData.sendQueue.len == 0:
    # Try sending some immediately.
    let ret = send(req.client, addr text[0], text.len, 0)
    if ret == -1:
      # Error!
      let lastError = osLastError()
      if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
        handleClientClosure(req.selector, req.client, false)
      if lastError.int32 notin {EWOULDBLOCK, EAGAIN}:
        raiseOSError(lastError)

    if ret != text.len:
      getData.sendQueue.add(text)
      getData.bytesSent = ret
      req.selector.updateHandle(req.client, {Event.Read, Event.Write})

  else:
    getData.sendQueue.add(text)
    req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc run*(onRequest: OnRequest) =
  let cores = countProcessors()
  if cores > 1:
    echo("Starting ", cores, " threads")
    var threads = newSeq[Thread[OnRequest]](cores)
    for i in 0 .. <cores:
      createThread[OnRequest](threads[i], eventLoop, onRequest)
    joinThreads(threads)
  else:
    eventLoop(onRequest)

when isMainModule:
  proc onRequest(req: Request) =
    req.send("Hello World")

  run(onRequest)