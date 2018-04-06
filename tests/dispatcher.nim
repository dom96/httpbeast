import options, asyncdispatch, httpclient

import httpbeast

proc onRequest(req: Request) {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      var client = newAsyncHttpClient()
      let content = await client.getContent("http://localhost:8080/content")
      req.send($content)
    of "/content":
      req.send("Hi there!")
    else:
      req.send(Http404)
  elif req.httpMethod == some(HttpPost):
    case req.path.get()
    of "/":
      req.send("Successful POST! Data=" & $req.body.get().len)
    else:
      req.send(Http404)

run(onRequest)