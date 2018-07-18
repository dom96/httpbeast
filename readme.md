# httpbeast

Extremely fast HTTP responses in Nim.

This is a project to get the fastest possible HTTP server written in pure Nim.
The server is still considered experimental but it is already used by the
Jester web framework.

**Note:** This HTTP server does not support Windows.

## Features

Current features include:

* Built on the Nim ``selectors`` module which makes efficient use of epoll on
  Linux and kqueue on macOS.
* Automatic parallelization, just make sure to compile with ``--threads:on``.
* Support for HTTP pipelining.
* On-demand parser so that only the requested data is parsed.
* Integration with Nim's ``asyncdispatch`` allowing async/await to be used in
  the request callback whenever necessary.