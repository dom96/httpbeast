import options

import httpbeast

proc onRequest(req: Request) =
  if req.reqMethod == some(HttpGet):
    req.send("Hello World")

run(onRequest)