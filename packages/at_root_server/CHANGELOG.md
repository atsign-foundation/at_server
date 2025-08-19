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
