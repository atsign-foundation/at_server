## 5.0.0

- fix: BREAKING: Change signature of AtConnection.write
  from `void write(String data)` to `Future<void> write(String data);`

## 4.0.1

- docs: updated CHANGELOG

## 4.0.0

- feat: at_server_spec: BREAKING: make AtConnection generic (i.e. not
  socket-specific) This is in order to enable reuse of the atServer's
  InboundConnectionManager class and InboundConnection interface for WebSocket
  connections as well as Socket connections
- feat: at_server_spec: BREAKING: rename AtConnection's getSocket()
  method to a getter called underlying and have it return the generic type for
  more idiomatic Dart code
- feat: at_server_spec: BREAKING: rename AtConnection's getMetaData()
  method to a getter called metaData for more idiomatic Dart code
- build: at_server_spec: upgrade dependencies

## 3.0.16

- build(deps): upgraded at_commons to v4.0.0

## 3.0.15

- feat: Introduce AtRateLimiter to limit the requests based on the criteria
  defined
- fix: Modify InboundConnection to implement AtRateLimiter to limit requests

## 3.0.14

- fix: Rename TOTP to OTP

## 3.0.13

- feat: added keys verb
- experimental: added totp verb

## 3.0.12

- feat: added enroll verb
- chore: upgraded at_commons version

## 3.0.11

- feat: Added 'notifyFetch' verb

## 3.0.10

- feat: Added clientVersion to AtConnectionMetaData

## 3.0.9

- Added documentation for 'config' verb to support dynamic config change
  functionality
- Upgraded at_commons dependency version to 3.0.18

## 3.0.8

- Exported 'NotifyRemove' verbs in package export

## 3.0.7

- Updated 'info' verb documentation to cover new functionality

## 3.0.6

- Exported 'info' and 'noop' verbs in package export, redux

## 3.0.5

- Exported update_meta.dart and verb.dart in package export
- Upgraded version of at_commons to 3.0.7

## 3.0.4

- Exported 'info' and 'noop' verbs in package export

## 3.0.3

- Added 'info' and 'noop' verbs

## 3.0.2

- updated dart docs for verbs

## 3.0.1

- at_commons version change for AtKey validations.

## 3.0.0

- Sync pagination feature

## 2.0.5

- at_commons version change for last notification time in monitor

## 2.0.4

- dart doc changes for verbs

## 2.0.3

- at_commons version change for stream resume

## 2.0.2

- at_commons version change

## 2.0.1

- at_commons version change

## 2.0.0

- Null safety upgrade

## 1.0.0

- Initial version, created by Stagehand

