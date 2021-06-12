import options, asyncdispatch, nativesockets, strutils

import httpbeast

var lastFd = -1
proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.send("Immediate")
    of "/1", "/2":
      let id = req.path.get()
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
      let id = req.path.get()
      # Force client closure.
      # Unlikely the user would do this, but we can add some nicer exception
      # just in case.
      if id.endsWith("/1"):
        req.forget()
        req.client.close()
      await sleepAsync(10_000)
      echo("Sleep finished, responding to request ", id)
      req.send("Delayed " & id)
    # TODO: Case where we asyncCheck some other proc that calls `send` on request?

run(onRequest)