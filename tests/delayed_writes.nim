# Note: This test isn't part of the test suite, just here for reference.

import options, asyncdispatch, random

import httpbeast

proc onRequest(req: Request): Future[void] =
  var res = newFuture[void]()
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      let sleepFut = sleepAsync(rand(2000))
      sleepFut.callback =
        proc () =
          req.send("Hello World")
          res.complete()
    else:
      req.send(Http404)
      res.complete()
  return res

run(onRequest, initSettings(numThreads=1, port=Port(5000)))