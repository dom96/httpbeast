import asynctools, asyncdispatch, os, httpclient, strutils

var serverProcess: AsyncProcess

proc readLoop(process: AsyncProcess, findSuccess: bool) {.async.} =
  while process.running:
    var buf = newString(256)
    let len = await readInto(process.outputHandle, addr buf[0], 256)
    buf.setLen(len)
    if findSuccess:
      if "Hint: operation successful" in buf:
        asyncCheck readLoop(process, false)
        return
    else:
      echo("Process:", buf.strip())

proc startServer(file: string) {.async.} =
  if not serverProcess.isNil and serverProcess.running:
    serverProcess.terminate()
    serverProcess = nil

  serverProcess = startProcess(findExe"nim", "", ["c", "-r", file])

  await readLoop(serverProcess, true)
  await sleepAsync(2000)

proc tests() {.async.} =
  let client = newAsyncHttpClient()

  await startServer("helloworld.nim")

  # Simple GET
  let resp = await client.get("http://localhost:8080")
  doAssert resp.code == Http200
  let body = await resp.body
  doAssert body == "Hello World"

when isMainModule:
  waitFor tests()