import options, asyncdispatch, json, os, strutils

import httpbeast

template trimHex(hex:string) :string = 
  var msg = "0"
  for i,h in hex :
    if h != '0' : 
      msg = hex[i..<hex.len]
      break
  msg

proc onRequest(req: Request): Future[void] {.async.} =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/json":
      const data = $(%*{"message": "Hello, World!"})
      req.send(Http200, data)
    of "/download":

      # const buflen = 10000
      # let fileName = "largefile.zip"
      # let ext = "zip"
      const buflen = 10
      let fileName = "download.nim"
      let ext = "nim"

      let f : File = open(fileName ,FileMode.fmRead)
      defer : close(f)

      let size = f.getFileSize()
      let headers = "Content-Type: application/" & ext & 
                    "\c\Lcontent-disposition: attachment; filename=\"" & fileName & "\"" & 
                    "\c\LTransfer-Encoding: chunked"
      var
        text = (
          "HTTP/1.1 200 OK\c\L" &
          "Content-Length: $#\c\L$#\c\L\c\L"
        ) % [$size, headers]
      
      # header
      req.unsafeSend(text)
      if not await req.rawflush(): return

      # read to send
      var buf = ""
      buf.setLen(buflen)
      while (let ret = f.readBuffer(addr buf[0], buflen); ret > 0) :
      
        # send chunked hex and content
        req.unsafeSend(trimHex(ret.toHex) & "\c\L" & buf[0..<ret] & "\c\L")
        if not await req.rawflush() : return

      # send chunked ending signal
      req.unsafeSend("0\c\L\c\L")

      # Even if flush fails,
      # because there is data in the sendQueue, it is processed in the eventloop
      discard await req.rawflush()
  
    else:
      req.send(Http404)

run(onRequest)
