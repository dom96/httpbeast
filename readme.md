# httpbeast

Extremely fast HTTP responses in Nim.

This is an experimental project to get the fastest possible HTTP server written in pure Nim.

## First phase

The first phase is to build an HTTP server that cheats to get as many req/s as possible (as benchmarked by wrk).
This phase is mostly complete. On a 2 vCPU, 2GB Digital Ocean VPS I was able to get it to almost 100k req/s with
2 threads. But keep in mind that the code cheats a lot, it doesn't parse the headers and it always replies with
the same message.

That said, this will allow me to track how much I am screwing up the performance as I add these extra
features to this HTTP library.
