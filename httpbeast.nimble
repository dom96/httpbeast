# Package

version       = "0.1.0"
author        = "Dominik Picheta"
description   = "A super-fast epoll-backed and parallel HTTP server."
license       = "MIT"

# Dependencies

requires "nim >= 0.17.3"

task helloworld, "Compiles and executes the hello world server.":
  exec "nim c -d:release -r tests/helloworld"