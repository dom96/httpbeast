# httpbeast

Extremely fast HTTP responses in Nim.

This is an experimental project to get the fastest possible HTTP server written
in pure Nim.

## Benchmarking

Plan is to benchmark against:

* tokio-minihttp (shamelessly stolen from TechEmpower benchmarks)
* simple Go hello world
* cpoll_cppsp (shamelessly stolen from TechEmpower benchmarks)

### Preparations

On both the client and server:

```
sysctl -w fs.file-max=100000
ulimit -n 10000
```

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

## How does wrk work?

(or appear to work?)

wrk seems to simply write the following as fast as possible

```
GET / HTTP/1.1
Host: <ip>:<port>
```

And at the same time read from each client as quickly as possible and count
the number of requests.

Strangely, writing multiple responses really quickly (faster than the
requests even come in) increases the requests/sec A LOT.

## References

- https://tools.ietf.org/html/rfc7230
- https://tools.ietf.org/html/rfc7231