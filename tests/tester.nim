import asynctools, asyncdispatch, os, httpclient, strutils

from osproc import execCmd

var serverProcess: AsyncProcess

proc readLoop(process: AsyncProcess, findSuccess: bool) {.async.} =
  while process.running:
    var buf = newString(256)
    let len = await readInto(process.outputHandle, addr buf[0], 256)
    buf.setLen(len)
    if findSuccess:
      if "Listening on" in buf:
        asyncCheck readLoop(process, false)
        return
      echo(buf.strip)
    else:
      echo("Process:", buf.strip())

  echo("Process terminated")
  # asynctools should probably export this:
  # process.close()

proc startServer(file: string) {.async.} =
  var file = "tests" / file
  if not serverProcess.isNil and serverProcess.running:
    serverProcess.terminate()
    # TODO: https://github.com/cheatfate/asynctools/issues/9
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
    serverProcess = nil

  # The nim process doesn't behave well when using `-r`, if we kill it, the
  # process continues running...
  doAssert execCmd("nimble c -y " & file) == QuitSuccess

  serverProcess = startProcess(file.changeFileExt(ExeExt))
  await readLoop(serverProcess, true)
  await sleepAsync(2000)

proc tests() {.async.} =
  await startServer("helloworld.nim")

  # Simple GET
  block:
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080/")
    doAssert resp.code == Http200
    let body = await resp.body
    doAssert body == "Hello World"

  await startServer("dispatcher.nim")

  # Test 'await' usage in dispatcher.
  block:
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080")
    doAssert resp.code == Http200
    let body = await resp.body
    doAssert body == "Hi there!"

  # Simple POST
  block:
    let client = newAsyncHttpClient()
    let resp = await client.post("http://localhost:8080", body="hello")
    doAssert resp.code == Http200
    let body = await resp.body
    doAssert body == "Successful POST! Data=5"

  echo("All good!")

when isMainModule:
  try:
    waitFor tests()
  finally:
    doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess