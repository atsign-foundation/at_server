## 2.2.1

- feat: the atDirectory answers HTTP on its Atsign Protocol port to a client
  that negotiates `http/1.1` by ALPN, as on its HTTPS port. A client that
  negotiates `atProtocol/1.0`, or no protocol, speaks the Atsign Protocol as
  before.
- feat: every HTTP answer carries `Access-Control-Allow-Origin: *` and closes
  its connection, and an HTTP connection that sends no complete request is
  closed within 10 seconds.
- feat: a redirect for a path below an atSign keeps the atSign first:
  `GET /@alice/x` redirects to `https://<atServer>/@alice/x`, which an
  atServer from 3.11.1 on reads as `/x`.
- feat: an atSign is matched in any spelling, over HTTP and the Atsign
  Protocol alike.
- fix: an HTTP request whose path does not decode is answered 400, and one
  the atDirectory cannot answer 500.
 - build(deps): Add pubspec.lock and use ^ in pubspec.yaml
- build: `at_utils` 3.5.0. In a log message, control characters other than a
  line feed, bidirectional formatting characters, and line and paragraph
  separators appear as escapes such as `\x1b` and `\u202e`, and each line
  after a line feed is indented by two spaces.
- build: `at_commons` ^5.21.0, as `at_utils` 3.5.0 requires; the lock takes
  5.23.0, and nothing the root server uses from it changes.

## 2.2.0

- feat: add https support for looking up atServer addresses
- feat: add support for redirects so can http GET from  
  `https://<root fqdn>/<atSign>/publickey` and get redirected to
  `https://<atServer fqdn:port>/publickey`
- build[deps]: multiple dependency upgrades

## 2.1.2
- build[deps]: Upgraded the following package:
  - args to v2.6.0
  - at_commons to v5.0.1
  - at_utils to v3.0.19
  - at_server_spec to v5.0.2
  - test to v1.25.8
  - coverage to v1.10.0
## 2.1.1
- dependency upgrade in pubspec for at_commons, at_server_spec, at_utils
## 2.1.0
- feat: rate limiting when looking up non-existent atSigns
- feat: miscellaneous logging enhancements
- fix: removed unnecessary 10-second delay during normal startup
## 2.0.5
- upgrade persistence spec version
## 2.0.4
- dependency upgrade in pubspec for at_commons, at_utils, at_server_spec
## 2.0.3
- at_commons version change for stream resume
