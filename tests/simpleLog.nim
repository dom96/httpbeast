import logging
import options, asyncdispatch

import .. / src / httpbeast


let logFile = open("tests/logFile.tmp", fmWrite)
var fileLog = newFileLogger(logFile)
addHandler(fileLog)

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      info("Requested /")
      flushFile(logFile)  # Only errors above lvlError auto-flush
      req.send("Hello World")
    else:
      error("404")
      req.send(Http404)

block:
  let settings = initSettings()

  run(onRequest, settings)
  logFile.close()
