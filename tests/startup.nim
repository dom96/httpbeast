import os, options, asyncdispatch, parsecfg, strutils, streams
import httpbeast

const CurDir = currentSourcePath.parentDir

var threadsOn {.threadvar.}: bool
var name {.threadvar.}: string

proc onRequest(req: Request): Future[void] =
  if req.httpMethod == some(HttpGet):
    case req.path.get()
    of "/":
      req.send("name:$#,threads:$#." % [name, $threadsOn])
    else:
      req.send(Http404)

var startup = proc () =
  let configFile = CurDir / "startup.ini"
  var f = newFileStream(configFile, fmRead)
  assert f != nil, "cannot open " & configFile
  var p: CfgParser
  var section: string
  open(p, f, configFile)
  while true:
    var e = next(p)
    case e.kind
    of cfgEof: break
    of cfgSectionStart:   ## a `[section]` has been parsed
        section = e.section
    of cfgKeyValuePair:
        if section == "Package" and e.key == "name":
          name = e.value
    of cfgOption:
        if e.key == "threads":
          if e.value == "on":
            threadsOn = true
    of cfgError:
        echo e.msg
  close(p)

run(onRequest, initSettings(startup = startup))
