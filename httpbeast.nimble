# Package

version       = "0.2.2"
author        = "Dominik Picheta"
description   = "A super-fast epoll-backed and parallel HTTP server."
license       = "MIT"

srcDir = "src"

# Dependencies

requires "nim >= 0.18.0"

# Test dependencies
# When https://github.com/cheatfate/asynctools/pull/28 is fixed,
# change this back to normal asynctools
requires "https://github.com/iffy/asynctools#pr_fix_for_latest"

task helloworld, "Compiles and executes the hello world server.":
  exec "nim c -d:release --gc:boehm -r tests/helloworld"

task dispatcher, "Compiles and executes the dispatcher test server.":
  exec "nim c -d:release --gc:boehm -r tests/dispatcher"

task test, "Runs the test suite.":
  exec "nimble c -y -r tests/tester"
