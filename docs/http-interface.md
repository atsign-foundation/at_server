# The atServer HTTP interface

An atServer answers HTTPS `GET` requests for its atSign's public keys. It
serves them on the same host and port as the atProtocol, and decides which of
the two a connection speaks during the TLS handshake.

## Reaching it

Find the atServer's host and port the same way an atProtocol client does: send
the atSign, without its `@`, to the atDirectory on its atProtocol port. It
answers `@<host>:<port>`.

```
printf 'alice\n' | openssl s_client -quiet -connect root.atsign.org:64
```

### ALPN `http/1.1` is required

The atServer offers two ALPN protocols, `atProtocol/1.0` and `http/1.1`. A
connection that negotiates `http/1.1` is served HTTP. A connection that
negotiates `atProtocol/1.0`, or no protocol at all, is served the atProtocol.

An HTTP client that offers no ALPN therefore reaches the atProtocol. The
atServer sends its `@` prompt, answers the request line with

```
error:AT0003-Exception: HTTP requests must negotiate ALPN http/1.1
```

and closes the connection. Most HTTP clients report this as a malformed
response rather than showing it; curl, for example, reports
`Received HTTP/0.9 when not allowed`.

curl offers `http/1.1` by default. Dart's `HttpClient` offers no ALPN, so give
it a `connectionFactory` that does; the control test in
[`http_without_alpn_test.dart`](../tests/at_functional_test/test/http_without_alpn_test.dart)
shows how.

### Through the atDirectory

Where the atDirectory's HTTPS port (`httpsPort`) is enabled,
`GET https://<atDirectory>/<atSign>/<path>?<query>` answers `302` with a
`Location` on the atServer, keeping the path and query. Without a path it
answers the atServer's `<host>:<port>`.

## Which key a path names

Only the atServer's own atSign's `public:` keys are served. The path is turned
into a key in these steps:

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

A key that does not exist, that is not public, or that holds an expired
enrollment's per-enrollment data answers `404`. A method other than `GET`
answers `405`, and a URI longer than 1000 characters answers `400`.

The path `/ws` is not a key: a request for it is upgraded to a WebSocket.

## What a response carries

The `at_rt` query parameter selects the content:

| `at_rt`  | Response body                                                  |
|----------|----------------------------------------------------------------|
| (absent) | The value                                                      |
| `meta`   | The key's metadata, as JSON                                    |
| `all`    | `{"key": …, "data": …, "metaData": {…}}`, as JSON              |

Fields whose value is null are left out of the metadata.

The `at_ct` query parameter sets the `Content-Type`. Without it, a `meta`
response is `application/json`, and anything else is the type the key's name
implies when read as a file path (`index.html.demo` is `demo/index.html`, so
`text/html`), or else `text/plain`, or `application/octet-stream` for a binary
value. An `all` response is therefore not labelled JSON unless the request
passes `at_ct=application/json`.

A binary value is returned as its decoded bytes, and `at_rt=all` returns those
bytes too, not JSON. Ask for its metadata separately with `at_rt=meta`.
