# httpbeast

Extremely fast HTTP responses in Nim.

This is an experimental project to get the fastest possible HTTP server written
in pure Nim.

## First phase

The first phase is to build an HTTP server that cheats to get as many req/s as
possible (as benchmarked by wrk).
This phase is mostly complete.

I benchmarked this by executing it on a 2 vCPU & 2GB Digital Ocean VPS, then
running `wrk -c256 -t2 http://ip:8080` on a separate VPS (on the same
private network).
I was able to get it to almost 100k req/s with 2 threads. But keep in mind that
the code cheats a lot, it doesn't parse the headers and it always replies with
the same message.

The reasoning for this is to give me an idea of the top performance I can
potentially get out of this code. Obviously my goal is to turn this into a
proper HTTP server without sacrificing any performance, but doing so is
likely impossible so I will settle for sacrificing as little as possible.
