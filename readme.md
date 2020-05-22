# httpbeast

Extremely fast HTTP responses in Nim.

This is a project to get the fastest possible HTTP server written in pure Nim. It is currently in the [top 10 in the TechEmpower benchmarks](https://www.techempower.com/benchmarks/#section=data-r18&hw=ph&test=json).

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
