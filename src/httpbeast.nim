import selectors, net, nativesockets, os, httpcore, asyncdispatch, strutils
import options

from osproc import countProcessors

import times # TODO this shouldn't be required. Nim bug?

export httpcore.HttpMethod

import httpbeast/parser

type
  Cache = object
    data: string
    response: string

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
    ## A cache of the previous request.
    cache: Option[Cache]

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
       headersFinished: false,
       cache: none(Cache)
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
                             inLoop=true) =
  # TODO: Logging that the socket was closed.
  selector.unregister(fd)
  fd.SocketHandle.close()
  when inLoop:
    break
  else:
    return

proc validateRequest(req: Request): bool {.gcsafe.}
proc processEvents(selector: Selector[Data],
                   events: array[64, ReadyKey], count: int,
                   onRequest: OnRequest) =
  for i in 0 .. <count:
    let fd = events[i].fd
    template data: var Data = selector.getData(fd)
    # Handle error events first.
    if Event.Error in events[i].events:
      if isDisconnectionError({SocketFlag.SafeDisconn},
                              events[i].errorCode):
        handleClientClosure(selector, fd)
      raiseOSError(events[i].errorCode)

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
        # Read until EAGAIN. We take advantage of the fact that the client
        # will wait for a response after they send a request. So we can
        # comfortably continue reading until the message ends with \c\l
        # \c\l.
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

          if buf[ret-1] == '\l' and buf[ret-2] == '\c' and
             buf[ret-3] == '\l' and buf[ret-4] == '\c':
            # First line and headers for request received.
            # TODO: For now we only support GET requests.
            # TODO: Check for POST and Content-Length in the most
            # TODO: optimised way possible!
            data.headersFinished = true
            assert data.sendQueue.len == 0
            assert data.bytesSent == 0
            # Check cache.
            let cache = data.cache
            if cache.isSome() and cache.get().data == data.data:
              # Reply with the cached response.
              data.sendQueue = cache.get().response
              selector.updateHandle(fd.SocketHandle,
                                    {Event.Read, Event.Write})
            else:
              let request = Request(
                selector: selector,
                client: fd.SocketHandle
              )

              if validateRequest(request):
                onRequest(request)

              # Save cache.
              # TODO: Register a timer to expire the cache.
              data.cache = some(
                Cache(data: data.data, response: data.sendQueue)
              )

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
          data.data.setLen(0)
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

proc send*(req: Request, code: HttpCode, body: string) =
  ## Responds with the specified HttpCode and body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.

  # TODO: Reduce the amount of `getData` accesses.
  template getData: var Data = req.selector.getData(req.client)
  assert getData.headersFinished, "Selector not ready to send."

  getData.headersFinished = false
  var
    text = "HTTP/1.1 $1\c\LContent-Length: $2\c\L\c\L$3" %
           [$code, $body.len, body]

  getData.sendQueue.add(text)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode) =
  ## Responds with the specified HttpCode. The body of the response
  ## is the same as the HttpCode description.
  req.send(code, $code)

proc send*(req: Request, body: string) {.inline.} =
  ## Sends a HTTP 200 OK response with the specified body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.
  req.send(Http200, body)

proc reqMethod*(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  reqMethod(req.selector.getData(req.client).data)

proc validateRequest(req: Request): bool =
  ## Handles protocol-mandated responses.
  ##
  ## Returns ``false`` when the request has been handled.
  result = true

  # From RFC7231: "When a request method is received
  # that is unrecognized or not implemented by an origin server, the
  # origin server SHOULD respond with the 501 (Not Implemented) status
  # code."
  if req.reqMethod().isNone():
    req.send(Http501)
    return false

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