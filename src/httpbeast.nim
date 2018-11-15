import selectors, net, nativesockets, os, httpcore, asyncdispatch, strutils
import parseutils
import options, future, logging

from deques import len

from osproc import countProcessors

import times # TODO this shouldn't be required. Nim bug?

export httpcore

import httpbeast/parser

type
  FdKind = enum
    Server, Client, Dispatcher

  Data = object
    fdKind: FdKind ## Determines the fd kind (server, client, dispatcher)
    ## - Client specific data.
    ## A queue of data that needs to be sent when the FD becomes writeable.
    sendQueue: string
    ## The number of characters in `sendQueue` that have been sent already.
    bytesSent: int
    ## Big chunk of data read from client during request.
    data: string
    ## Determines whether `data` contains "\c\l\c\l".
    headersFinished: bool
    ## Determines position of the end of "\c\l\c\l".
    headersFinishPos: int
    ## The address that a `client` connects from.
    ip: string

type
  Request* = object
    selector: Selector[Data]
    client: SocketHandle
    # Determines where in the data buffer this request starts.
    # Only used for HTTP pipelining.
    start: int

  OnRequest* = proc (req: Request): Future[void] {.gcsafe.}

  Settings* = object
    port*: Port
    bindAddr*: string

const
  serverInfo = "HttpBeast"

proc initSettings*(port: Port = Port(8080), bindAddr: string = ""): Settings =
  Settings(
    port: port,
    bindAddr: bindAddr
  )

proc initData(fdKind: FdKind, ip = ""): Data =
  Data(fdKind: fdKind,
       sendQueue: "",
       bytesSent: 0,
       data: "",
       headersFinished: false,
       headersFinishPos: -1, ## By default we assume the fast case: end of data.
       ip: ip
      )

template handleAccept() =
  let (client, address) = fd.SocketHandle.accept()
  if client == osInvalidSocket:
    let lastError = osLastError()
    raiseOSError(lastError)
  setBlocking(client, false)
  selector.registerHandle(client, {Event.Read},
                          initData(Client, ip=address))

template handleClientClosure(selector: Selector[Data],
                             fd: SocketHandle|int,
                             inLoop=true) =
  # TODO: Logging that the socket was closed.

  # TODO: Can POST body be sent with Connection: Close?

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

template fastHeadersCheck(data: ptr Data): untyped =
  (let res = data.data[^1] == '\l' and data.data[^2] == '\c' and
             data.data[^3] == '\l' and data.data[^4] == '\c';
   if res: data.headersFinishPos = data.data.len;
   res)

template methodNeedsBody(data: ptr Data): untyped =
  (
    # Only idempotent methods can be pipelined (GET/HEAD/PUT/DELETE), they
    # never need a body, so we just assume `start` at 0.
    let m = parseHttpMethod(data.data, start=0);
    m.isSome() and m.get() in {HttpPost, HttpPut, HttpConnect, HttpPatch}
  )

proc slowHeadersCheck(data: ptr Data): bool =
  # TODO: See how this `unlikely` affects ASM.
  if unlikely(methodNeedsBody(data)):
    # Look for \c\l\c\l inside data.
    data.headersFinishPos = 0
    template ch(i): untyped =
      (
        let pos = data.headersFinishPos+i;
        if pos >= data.data.len: '\0' else: data.data[pos]
      )
    while data.headersFinishPos < data.data.len:
      case ch(0)
      of '\c':
        if ch(1) == '\l' and ch(2) == '\c' and ch(3) == '\l':
          data.headersFinishPos.inc(4)
          return true
      else: discard
      data.headersFinishPos.inc()

    data.headersFinishPos = -1

proc bodyInTransit(data: ptr Data): bool =
  assert methodNeedsBody(data), "Calling bodyInTransit now is inefficient."
  assert data.headersFinished

  if data.headersFinishPos == -1: return false

  var trueLen = parseContentLength(data.data, start=0)

  let bodyLen = data.data.len - data.headersFinishPos
  assert(not (bodyLen > trueLen))
  return bodyLen != trueLen

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
          let origLen = data.data.len
          data.data.setLen(origLen + ret)
          for i in 0 ..< ret: data.data[origLen+i] = buf[i]

          if fastHeadersCheck(data) or slowHeadersCheck(data):
            # First line and headers for request received.
            data.headersFinished = true
            when not defined(release):
              if data.sendQueue.len != 0:
                logging.warn("sendQueue isn't empty.")
              if data.bytesSent != 0:
                logging.warn("bytesSent isn't empty.")

            let waitingForBody = methodNeedsBody(data) and bodyInTransit(data)
            if likely(not waitingForBody):
              for start in parseRequests(data.data):
                # For pipelined requests, we need to reset this flag.
                data.headersFinished = true

                let request = Request(
                  selector: selector,
                  client: fd.SocketHandle,
                  start: start
                )

                template validateResponse(): untyped =
                  data.headersFinished = false

                if validateRequest(request):
                  let fut = onRequest(request)
                  if not fut.isNil:
                    fut.callback =
                      proc (theFut: Future[void]) =
                        onRequestFutureComplete(theFut, selector, fd)
                        validateResponse()
                  else:
                    validateResponse()

          if ret != size:
            # Assume there is nothing else for us right now and break.
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

var serverDate {.threadvar.}: string
proc updateDate(fd: AsyncFD): bool =
  result = false # Returning true signifies we want timer to stop.
  serverDate = now().utc().format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc eventLoop(params: (OnRequest, Settings)) =
  let (onRequest, settings) = params

  let selector = newSelector[Data]()

  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(settings.port, settings.bindAddr)
  server.listen()
  server.getFd().setBlocking(false)
  selector.registerHandle(server.getFd(), {Event.Read}, initData(Server))

  let disp = getGlobalDispatcher()
  selector.registerHandle(getIoHandler(disp).getFd(), {Event.Read},
                          initData(Dispatcher))

  # Set up timer to get current date/time.
  discard updateDate(0.AsyncFD)
  asyncdispatch.addTimer(1000, false, updateDate)

  var events: array[64, ReadyKey]
  while true:
    let ret = selector.selectInto(-1, events)
    processEvents(selector, events, ret, onRequest)

    # Ensure callbacks list doesn't grow forever in asyncdispatch.
    # See https://github.com/nim-lang/Nim/issues/7532.
    # Not processing callbacks can also lead to exceptions being silently
    # lost!
    if unlikely(asyncdispatch.getGlobalDispatcher().callbacks.len > 0):
      asyncdispatch.poll(0)

#[ API start ]#

proc unsafeSend*(req: Request, data: string) {.inline.} =
  ## Sends the specified data on the request socket.
  ##
  ## This function can be called as many times as necessary.
  ##
  ## It does not
  ## check whether the socket is in a state that can be written so be
  ## careful when using it.
  if req.client notin req.selector:
    return
  req.selector.getData(req.client).sendQueue.add(data)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc prepareHeaders(bodySize: int, serverInfo, serverDate: string,  headers=""): string =
  if headers == "":
    return "Content-Length: $#\c\LServer: $#\c\LDate: $#" % [$bodySize, serverInfo, serverDate]

  var
    headerList = headers.split("\c\L")
    hasContentLength = false
    hasServer = false
    hasDate = false

  for header in headerList:
    if header.startsWith("Content-Length: "): hasContentLength = true
    if header.startsWith("Server: "): hasServer = true
    if header.startsWith("Date: "): hasDate = true

  if not hasContentLength:
    headerList.add("Content-Length: $#" % [$bodySize])

  if not hasServer:
    headerList.add("Server: $#" % [serverInfo])

  if not hasDate:
    headerList.add("Date: $#" % [serverDate])

  result = join(headerList, "\c\L")

proc send*(req: Request, code: HttpCode, body: string, headers="") =
  ## Responds with the specified HttpCode and body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.

  if req.client notin req.selector:
    return

  # TODO: Reduce the amount of `getData` accesses.
  template getData: var Data = req.selector.getData(req.client)
  assert getData.headersFinished, "Selector not ready to send."

  let responseHeaders = prepareHeaders(body.len, serverInfo, serverDate, headers)
  var
    text = (
      "HTTP/1.1 $#\c\L" &
      "$#\c\L\c\L$#"
    ) % [$code, responseHeaders, body]

  getData.sendQueue.add(text)
  req.selector.updateHandle(req.client, {Event.Read, Event.Write})

proc send*(req: Request, code: HttpCode) =
  ## Responds with the specified HttpCode. The body of the response
  ## is the same as the HttpCode description.
  req.send(code, $code)

proc send*(req: Request, body: string, code = Http200) {.inline.} =
  ## Sends a HTTP 200 OK response with the specified body.
  ##
  ## **Warning:** This can only be called once in the OnRequest callback.
  req.send(code, body)

proc httpMethod*(req: Request): Option[HttpMethod] {.inline.} =
  ## Parses the request's data to find the request HttpMethod.
  parseHttpMethod(req.selector.getData(req.client).data, req.start)

proc path*(req: Request): Option[string] {.inline.} =
  ## Parses the request's data to find the request target.
  parsePath(req.selector.getData(req.client).data, req.start)

proc headers*(req: Request): Option[HttpHeaders] =
  ## Parses the request's data to get the headers.
  parseHeaders(req.selector.getData(req.client).data, req.start)

proc body*(req: Request): Option[string] =
  ## Retrieves the body of the request.
  let pos = req.selector.getData(req.client).headersFinishPos
  if pos == -1: return none(string)
  result = req.selector.getData(req.client).data[
    pos .. ^1
  ].some()

  when not defined(release):
    let length =
      if req.headers.get().hasKey("Content-Length"):
        req.headers.get()["Content-Length"].parseInt()
      else:
        0
    assert result.get().len == length

proc ip*(req: Request): string =
  ## Retrieves the IP address that the request was made from.
  req.selector.getData(req.client).ip

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
  when compileOption("threads"):
    let cores = countProcessors()
  else:
    let cores = 1

  echo("Starting ", cores, " threads")
  if cores > 1:
    when compileOption("threads"):
      var threads = newSeq[Thread[(OnRequest, Settings)]](cores)
      for i in 0 ..< cores:
        createThread[(OnRequest, Settings)](
          threads[i], eventLoop, (onRequest, settings)
        )
      echo("Listening on port ", settings.port) # This line is used in the tester to signal readiness.
      joinThreads(threads)
    else:
      assert false
  else:
    eventLoop((onRequest, settings))

proc run*(onRequest: OnRequest) {.inline.} =
  ## Starts the HTTP server with default settings. Calls `onRequest` for each
  ## request.
  ##
  ## See the other ``run`` proc for more info.
  run(onRequest, Settings(port: Port(8080), bindAddr: ""))

when false:
  proc close*(port: Port) =
    ## Closes an httpbeast server that is running on the specified port.
    ##
    ## **NOTE:** This is not yet implemented.

    assert false
    # TODO: Figure out the best way to implement this. One way is to use async
    # events to signal our `eventLoop`. Maybe it would be better not to support
    # multiple servers running at the same time?