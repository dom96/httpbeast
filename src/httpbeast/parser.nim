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
