import selectors, net, nativesockets, os, httpcore, asyncdispatch, strutils
import options, future

from osproc import countProcessors

import times # TODO this shouldn't be required. Nim bug?

export httpcore

import httpbeast/parser

type
  FdKind = enum
    Server, Client, Dispatcher

  Data = object
    fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
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

  OnRequest* = proc (req: Request): Future[void] {.gcsafe.}

  Settings* = object
    port: Port

proc initData(fdKind: FdKind): Data =
  Data(fdKind: fdKind,
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
                          initData(Client))

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

proc onRequestFutureComplete(theFut: Future[void],
                             selector: Selector[Data], fd: int) =
  if theFut.failed:
    raise theFut.error

proc validateRequest(req: Request): bool {.gcsafe.}
proc processEvents(selector: Selector[Data],
                   events: array[64, ReadyKey], count: int,
                   onRequest: OnRequest) =
  for i in 0 ..< count:
    let fd = events[i].fd
    var data: ptr Data = addr(selector.getData(fd))
    # Handle error events first.
    if Event.Error in events[i].events:
      if isDisconnectionError({SocketFlag.SafeDisconn},
                              events[i].errorCode):
        handleClientClosure(selector, fd)
      raiseOSError(events[i].errorCode)

    case data.fdKind
    of Server:
      if Event.Read in events[i].events:
        handleAccept()
      else:
        assert false, "Only Read events are expected for the server"
    of Dispatcher:
      # Run the dispatcher loop.
      assert events[i].events == {Event.Read}
      asyncdispatch.poll(0)
    of Client:
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

          if data.data[^1] == '\l' and data.data[^2] == '\c' and
             data.data[^3] == '\l' and data.data[^4] == '\c':
            # First line and headers for request received.
            # TODO: For now we only support GET requests.
            # TODO: Check for POST and Content-Length in the most
            # TODO: optimised way possible!
            data.headersFinished = true
            assert data.sendQueue.len == 0
            assert data.bytesSent == 0

            let request = Request(
              selector: selector,
              client: fd.SocketHandle
            )

            if validateRequest(request):
              let fut = onRequest(request)
              if not fut.isNil:
                fut.callback =
                  (theFut: Future[void]) =>
                    (onRequestFutureComplete(theFut, selector, fd))

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

proc eventLoop(params: (OnRequest, Settings)) =
  let (onRequest, settings) = params

  let selector = newSelector[Data]()

  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(settings.port)
  server.listen()
  server.getFd().setBlocking(false)
  selector.registerHandle(server.getFd(), {Event.Read}, initData(Server))

  let disp = getGlobalDispatcher()
  selector.registerHandle(getIoHandler(disp).getFd(), {Event.Read},
                          initData(Dispatcher))

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

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).data)

proc path*(req: Request): Option[string] {.inline.} =
  ## Parses the request's data to find the request target.
  parsePath(req.selector.getData(req.client).data)

proc validateRequest(req: Request): bool =
  ## Handles protocol-mandated responses.
  ##
  ## Returns ``false`` when the request has been handled.
  result = true

  # From RFC7231: "When a request method is received
  # that is unrecognized or not implemented by an origin server, the
  # origin server SHOULD respond with the 501 (Not Implemented) status
  # code."
  if req.httpMethod().isNone():
    req.send(Http501)
    return false

proc run*(onRequest: OnRequest, settings: Settings) =
  ## Starts the HTTP server and calls `onRequest` for each request.
  ##
  ## The ``onRequest`` procedure returns a ``Future[void]`` type. But
  ## unlike most asynchronous procedures in Nim, it can return ``nil``
  ## for better performance, when no async operations are needed.
  let cores = countProcessors()
  if cores > 1:
    echo("Starting ", cores, " threads")
    var threads = newSeq[Thread[(OnRequest, Settings)]](cores)
    for i in 0 ..< cores:
      createThread[(OnRequest, Settings)](threads[i], eventLoop, (onRequest, settings))
    joinThreads(threads)
  else:
    eventLoop((onRequest, settings))

proc run*(onRequest: OnRequest) {.inline.} =
  ## Starts the HTTP server with default settings. Calls `onRequest` for each
  ## request.
  ##
  ## See the other ``run`` proc for more info.
  run(onRequest, Settings(port: Port(8080)))