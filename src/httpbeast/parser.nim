import options, httpcore

proc parseHttpMethod*(data: string): Option[HttpMethod] =
  ## Parses the data to find the request HttpMethod.

  # HTTP methods are case sensitive.
  # (RFC7230 3.1.1. "The request method is case-sensitive.")
  case data[0]
  of 'G':
    if data[1] == 'E' and data[2] == 'T':
      return some(HttpGet)
  of 'H':
    if data[1] == 'E' and data[2] == 'A' and data[3] == 'D':
      return some(HttpHead)
  of 'P':
    if data[1] == 'O' and data[2] == 'S' and data[3] == 'T':
      return some(HttpPost)
    if data[1] == 'U' and data[2] == 'T':
      return some(HttpPut)
  else: discard

  return none(HttpMethod)

proc parsePath*(data: string): Option[string] =
  ## Parses the request path from the specified data.

  # Find the first ' '.
  # We can actually start ahead a little here. Since we know
  # the shortest HTTP method: 'GET'/'PUT'.
  var i = 2
  while data[i] notin {' ', '\0'}: i.inc()

  if likely(data[i] == ' '):
    # Find the second ' '.
    i.inc() # Skip first ' '.
    let start = i
    while data[i] notin {' ', '\0'}: i.inc()

    if likely(data[i] == ' '):
      return some(data[start..<i])
  else:
    return none(string)

proc parseHeaders*(data: string): Option[HttpHeaders] =
  var pairs: seq[(string, string)] = @[]

  var i = 0
  # Skip first line containing the method, path and HTTP version.
  while data[i] != '\l': i.inc

  i.inc # Skip \l

  var value = false
  var current: (string, string) = ("", "")
  while i < data.len:
    case data[i]
    of ':':
      if value: current[1].add(':')
      value = true
    of ' ':
      if value:
        if current[1].len != 0:
          current[1].add(data[i])
      else:
        current[0].add(data[i])
    of '\c':
      discard
    of '\l':
      if current[0].len == 0:
        # End of headers.
        return some(newHttpHeaders(pairs))

      pairs.add(current)
      value = false
      current = ("", "")
    else:
      if value:
        current[1].add(data[i])
      else:
        current[0].add(data[i])
    i.inc()

  return none(HttpHeaders)