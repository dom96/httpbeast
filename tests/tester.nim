import asynctools, asyncdispatch, os, httpclient, strutils, asyncnet

from unittest import check, abortOnError
abortOnError = true

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

  # Verify that another server isn't already running.
  doAssertRaises(OSError):
    let client = newAsyncHttpClient()
    let data = await client.getContent("http://localhost:8080/")
    echo("Got data from server: ", data)
    echo("Received data from server, which means that stale serve is running.")

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
    check resp.code == Http200
    let body = await resp.body
    check body == "Hello World"

  await startServer("dispatcher.nim")

  # Test 'await' usage in dispatcher.
  block:
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080")
    check resp.code == Http200
    let body = await resp.body
    check body == "Hi there!"

  # Simple POST
  block:
    let client = newAsyncHttpClient()
    let resp = await client.post("http://localhost:8080", body="hello")
    check resp.code == Http200
    let body = await resp.body
    check body == "Successful POST! Data=5"

  await startServer("simpleLog.nim")

  # Check that configured loggers are passed to each thread
  let logFilename = "tests/logFile.tmp"
  block:
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080")
    check resp.code == Http200
    let file = open(logFilename)
    check "INFO Requested /" in file.readAll()
    file.close()

  check tryRemoveFile(logFilename)
  await startServer("simpleLog.nim")

  block:
    let client = newAsyncHttpClient()
    let resp = await client.get("http://localhost:8080/404")
    check resp.code == Http404
    let file = open(logFilename)
    let contents = file.readAll()
    file.close()
    check "INFO Requested /404" in contents
    check "ERROR 404" in contents

  check tryRemoveFile(logFilename)

  # Verify cross-talk doesn't occur
  await startServer("crosstalk.nim")
  block:
    var client = newAsyncSocket()
    await client.connect("localhost", Port(8080))
    await client.send("GET /1 HTTP/1.1\c\l\c\l")
    client.close()

    client = newAsyncSocket()
    defer: client.close()
    await client.connect("localhost", Port(8080))
    await client.send("GET /2 HTTP/1.1\c\l\c\l")

    check (await client.recvLine()) == "HTTP/1.1 200 OK"
    check (await client.recvLine()) == "Content-Length: 10"
    check (await client.recvLine()).startsWith("Server")
    check (await client.recvLine()).startsWith("Date:")
    check (await client.recvLine()) == "\c\l"
    let delayedBody = await client.recv(10)
    doAssert(delayedBody == "Delayed /2", "We must get the ID we asked for.")

  await startServer("crosstalk.nim")
  block:
    var client = newAsyncSocket()
    await client.connect("localhost", Port(8080))
    await client.send("GET /close_me/1 HTTP/1.1\c\l\c\l")
    check (await client.recv(1)) == ""
    client.close()

    client = newAsyncSocket()
    defer: client.close()
    await client.connect("localhost", Port(8080))
    await client.send("GET /close_me/2 HTTP/1.1\c\l\c\l")
    check (await client.recvLine()) == "HTTP/1.1 200 OK"
    check (await client.recvLine()) == "Content-Length: 19"
    check (await client.recvLine()).startsWith("Server")
    check (await client.recvLine()).startsWith("Date:")
    check (await client.recvLine()) == "\c\l"
    let delayedBody = await client.recv(19)
    doAssert(delayedBody == "Delayed /close_me/2", "We must get the ID we asked for.")

  echo("All good!")

when isMainModule:
  try:
    waitFor tests()
  finally:
    if not serverProcess.isNil:
      doAssert execCmd("kill -15 " & $serverProcess.processID()) == QuitSuccess
