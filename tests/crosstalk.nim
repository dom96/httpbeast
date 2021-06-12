import options, asyncdispatch, nativesockets, strutils

import httpbeast

proc nonAwaitedDelayedSend(req: Request, id: string) {.async.} =
  await sleepAsync(10_000)
  echo("Sleep finished, responding to request ", id)
  req.send("Delayed " & id)

var lastFd = -1
proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    let id = req.path.get()
    case id
    of "/":
      req.send("Immediate")
    of "/1", "/2":
      # TODO: Can we replace this sleep?
      await sleepAsync(1_000)
      echo("Sleep finished, responding to request ", id)
      req.send("Delayed " & id)
    of "/close_me/1", "/close_me/2":
      # To reproduce this bug we expect the OS to reuse the OS.
      if lastFd == -1:
        lastFd = req.client.int
      else:
        if lastFd != req.client.int:
          echo("WARNING: Received different FDs, test doesn't give signal.")
      # Force client closure.
      # Unlikely the user would do this, but we can add some nicer exception
      # just in case.
      if id.endsWith("/1"):
        req.forget()
        req.client.close()
      await sleepAsync(1_000)
      echo("Sleep finished, responding to request ", id)
      try:
        req.send("Delayed " & id)
      except HttpBeastDefect:
        return
      except:
        doAssert(false, "Different exception raised: " & getCurrentException().msg)
      doAssert(id == "/close_me/2", "Nothing raised for first request.")
    of "/asyncCheck/1", "/asyncCheck/2":
      asyncCheck nonAwaitedDelayedSend(req, id)


run(onRequest)