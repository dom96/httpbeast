import selectors, net, nativesockets, os

import times # TODO this shouldn't be required. Nim bug?

type
  Data = object
    isServer: bool
    sendQueue: string

proc initData(isServer: bool): Data =
  Data(isServer: isServer, sendQueue: "")

proc processEvents(selector: Selector[Data],
                   events: array[64, ReadyKey], count: int) =
  for i in 0 .. <count:
    let fd = events[i].fd
    var data = selector.getData(fd)
    if data.isServer:
      if Event.Read in events[i].events:
        let (client, address) = fd.SocketHandle.accept()
        setBlocking(client, false)
        selector.registerHandle(client, {Event.Read},
                                initData(false))
      else:
        assert false
    else:
      if Event.Read in events[i].events:
        assert data.sendQueue.len == 0
        # Read until EAGAIN. Hacky, but should work :)
        const size = 256
        var buf: array[size, char]
        while true:
          let ret = recv(fd.SocketHandle, addr buf[0], size, 0.cint)
          if ret == 0:
            echo("Client closed")
            selector.unregister(fd)
            fd.SocketHandle.close()
            break

          if ret == -1:
            # Error!
            let lastError = osLastError()
            if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
              break
            if isDisconnectionError({SocketFlag.SafeDisconn}, lastError):
              echo("Client closed")
              selector.unregister(fd)
              fd.SocketHandle.close()
              break
            raiseOSError(lastError)

          if buf[ret-1] == '\l' and buf[ret-2] == '\c':
            # Request finished.
            selector.withData(fd, value) do:
              value.sendQueue =
                "HTTP/1.1 200 OK\c\LContent-Length: 11\c\L\c\LHello World"
            selector.updateHandle(fd.SocketHandle,
                                  {Event.Read, Event.Write})

          if ret != size:
            # Assume there is nothing else for us and break.
            break
      elif Event.Write in events[i].events:
        assert data.sendQueue.len > 0
        # Write the sendQueue.
        let ret = send(fd.SocketHandle, addr data.sendQueue[0],
                       data.sendQueue.len, 0)
        if ret == -1:
          # Error!
          let lastError = osLastError()
          if lastError.int32 in {EWOULDBLOCK, EAGAIN}:
            break
          raiseOSError(lastError)

        # TODO: Optimise
        data.sendQueue = data.sendQueue[ret .. ^1]
        doAssert selector.setData(fd, data)

        if data.sendQueue.len == 0:
          selector.updateHandle(fd.SocketHandle,
                                {Event.Read})
      else:
        assert false

proc main() =
  let selector = newSelector[Data]()

  let server = newSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(Port(8080))
  server.listen()
  server.getFd().setBlocking(false)
  selector.registerHandle(server.getFd(), {Event.Read}, initData(true))

  var events: array[64, ReadyKey]
  while true:
    let ret = selector.selectInto(-1, events)
    processEvents(selector, events, ret)

main()