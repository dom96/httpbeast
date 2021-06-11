import options, asyncdispatch

import httpbeast

proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.send("Immediate")
    else:
      let id = req.path.get()
      # TODO: Can we replace this sleep?
      await sleepAsync(1_000)
      echo("Sleep finished, responding to request ", id)
      req.send("Delayed " & id)

run(onRequest)