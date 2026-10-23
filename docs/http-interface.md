# The atServer HTTP interface

An atServer answers HTTPS `GET` requests for its atSign's `public:` records.
It serves them on the same host and port as the Atsign Protocol, and decides
which of the two a connection speaks during the TLS handshake.

## Reaching it

Find the atServer's host and port the same way an Atsign Protocol client does:
send the atSign, without its `@`, to the atDirectory on its Atsign Protocol
port. It
answers `@<host>:<port>`, and `@exit`, sent on its own, closes the connection.

```
(printf 'alice\n'; sleep 1; printf '@exit\n') |
  openssl s_client -quiet -connect root.atsign.org:64
```

### ALPN `http/1.1` is required

The atServer offers two ALPN protocols, `atProtocol/1.0` and `http/1.1`. A
connection that negotiates `http/1.1` is served HTTP. A connection that
negotiates `atProtocol/1.0`, or no protocol at all, is served the Atsign
Protocol.

An HTTP client that offers no ALPN therefore reaches the Atsign Protocol. The
atServer sends its `@` prompt, answers the request line with

```
error:AT0003-Exception: HTTP requests must negotiate ALPN http/1.1
```

and closes the connection. Most HTTP clients report this as a malformed
response rather than showing it; curl, for example, reports
`Received HTTP/0.9 when not allowed`.

curl offers `http/1.1` by default. Dart's `HttpClient` offers no ALPN with the
default security context, so give it one that does, as `newHttpClient()` in
[`http_test.dart`](../tests/at_functional_test/test/http_test.dart) does:
`SecurityContext(withTrustedRoots: true)..setAlpnProtocols(['http/1.1'], false)`.
Only that client's connections use the context, so it does not change what
other Atsign Protocol connections in the same process negotiate.

### How long a connection is held

An HTTP connection to an atServer may carry several requests. Once its TLS
handshake has completed, a connection with no request in progress, or one that
sends part of a request and then nothing, is closed within 10 seconds, and one
whose answer is not fully sent within 30 seconds of its request, as when the
client reads none of it, is closed then. An
atServer holds at most `connection.http_max_limit` HTTP connections at once,
50 by default and none when it is 0 or less, apart from its Atsign Protocol
connections; a connection beyond that is closed without an answer. A
connection upgraded to a WebSocket at `/ws` is held as an Atsign Protocol
connection instead.

### Through the atDirectory

The atDirectory, like an atServer, answers HTTP on its Atsign Protocol port to
a connection that negotiates `http/1.1` by ALPN, and on its
HTTPS port too where that server is enabled (`httpsEnabled`, on `httpsPort`).
`GET https://<atDirectory>/@<atSign>/<path>?<query>` answers `302` with a
`Location` on the atServer that keeps the atSign, path and query,
`https://<host>:<port>/@<atSign>/<path>?<query>`, which an atServer from
3.11.1 on reads as `/<path>`, since it removes a leading `@<atSign>/` (see
[which key a path names](#which-key-a-path-names)). Without a path it answers
the atServer's `<host>:<port>`. An atSign it does not hold answers `404`, and a
method other than `GET` answers `401`.

Each HTTP connection to the atDirectory carries one request: the answer ends
with `Connection: close`. Every answer carries
`Access-Control-Allow-Origin: *`, so a web page on any origin can read it, and
once its TLS handshake has completed, a connection that sends no complete
request is closed within 10 seconds.

## Which key a path names

Only the atServer's own atSign's `public:` records are served. The path is
turned into a key in these steps:

1. Leading `/`s, then a leading `@<atSign>/`, are removed.
2. A leading `public:` and a trailing `@<atSign>` are removed.
3. The `/`-separated segments are reversed and joined with `.`.
4. `public:` and `@<atSign>` are added back.

For `@alice`:

| Path                      | Key                            |
|---------------------------|--------------------------------|
| `/publickey`              | `public:publickey@alice`       |
| `/location.wavi`          | `public:location.wavi@alice`   |
| `/wavi/location`          | `public:location.wavi@alice`   |
| `/@alice/demo/index.html` | `public:index.html.demo@alice` |

A key that does not exist, that is not public, that holds an expired
enrollment's per-enrollment data, or that cannot be read answers `404`. A URI
longer than 1000 characters answers `400`; otherwise a method other than `GET`
answers `405`. A `GET` whose path or query does not decode answers `400`, and
one that fails once its record has been read answers `500`.

The path `/ws` is not a key: a request for it is upgraded to a WebSocket.

## What a response carries

The `at_rt` query parameter selects the content:

| `at_rt`  | Response body                                                  |
|----------|----------------------------------------------------------------|
| (absent) | The value                                                      |
| `meta`   | The key's metadata, as JSON                                    |
| `all`    | `{"key": …, "data": …, "metaData": {…}}`, as JSON              |

Fields whose value is null are left out of the metadata.

A `meta` response is always `application/json`. Any other response's
`Content-Type` is the `at_ct` query parameter when one is passed, else the type
the key's name implies when read as a file path (`index.html.demo` is
`demo/index.html`, so `text/html`), else `text/plain`, or
`application/octet-stream` for a binary value. So an `all` response is labelled
JSON only when it passes `at_ct=application/json` or its key's name, read as a
file path, names a `.json` file.

A binary value is returned as its decoded bytes, and `at_rt=all` returns those
bytes too, not JSON. Ask for its metadata separately with `at_rt=meta`.
