import options, httpcore

proc reqMethod*(data: string): Option[HttpMethod] =
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