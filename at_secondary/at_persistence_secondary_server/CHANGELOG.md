## 3.0.29
- Introduced option to stop current schedule of a compaction job
- Enable the public hidden keys to sync between local and cloud secondary
- Uptake at_commons to 3.0.18 to optionally display hidden keys in scan
## 3.0.28
- Updated lastSyncedEntryCacheMap regex to match the reserved keys
- Upgraded to version 2.0.6 of at_persistence_spec containing @server/@client annotations
## 3.0.27
- Downgrade meta package to 1.7.0(minimum) version
## 3.0.26
- Replace null commitId's with hive internal key on secondary server startup
- Return commit entry with highest commitId from lastSyncedEntry
- Upgrade at_commons version for AtException hierarchy
## 3.0.25
- To reduce latency on notifications, publish the event for the notification before persisting the notification 
## 3.0.24
- Introduced a cache to speed up metaData retrieval.
- Removed unnecessary print statements
## 3.0.23
- Add remove method in NotificationManagerSpec.
## 3.0.22
- Bumped some dependencies
## 3.0.21
- Upgrade at_lookup and at_commons for NotifyRemove
## 3.0.20
- Upgrade Hive version to 2.1.0
## 3.0.19
- add encryption shared key and public key checksum to metadata
## 3.0.18
- Renamed compaction stats attributes
- Modified return type and added optional params in hive keystore put and create methods
## 3.0.17
- Support to collect and store compaction statistics
## 3.0.16
- at_lookup version upgrade for implementing server error responses
- at_commons version upgrade for AtTimeoutException
## 3.0.15
- at_utils version upgrade
## 3.0.14
- Fix commit log compaction issue.
## 3.0.13
- at_utils and at_commons version upgrade.
- Fix notification expiry bug.
## 3.0.12
- Changes to support reset of ttb
## 3.0.11
- Enhance commit log compaction service
## 3.0.10
- persistence spec version upgrade
## 3.0.9
- Added support for notification expiry based on ttl
## 3.0.8
- at_utils and at_commons version upgrade.
## 3.0.7
- compaction delete bug fix
- reduce compaction frequency to 12 hours
## 3.0.6
- Support for Hive lazy and in memory boxes
## 3.0.5
- Rollback hive lazy box
## 3.0.4
- Remove compaction strategy
## 3.0.3
- Fix for sync bug in commit log
## 3.0.2
- Add null check in commitLog KeyStore
## 3.0.1
- Change Hive box type to lazy box
## 3.0.0
- Sync pagination feature
## 2.0.6
- fix for hive closed box issue
## 2.0.5
- logs for hive closed box issue
## 2.0.4
- at_commons version change for last notification time in monitor
## 2.0.3
- at_commons version change for stream resume
## 2.0.2
- at_commons version change
## 2.0.1
- at_commons version change
## 2.0.0
- Null safety upgrade
## 1.0.1+8
- Refactor code with dart lint rules
- Fixed minor bug in secondary persistence store factory
## 1.0.1+7
- Third party package dependency upgrade
## 1.0.1+6
- Add await on close methods.
## 1.0.1+5
- Notification sub system changes
## 1.0.1+4
- Added Support for multiple AtSigns
- Introduced batch verb for sync
## 1.0.1+3
- Public data Signing
- Sync with regex
- at_persistence_spec changes
## 1.0.1+2
- Notifylist issue fix for atSigns with emojis Add close methods for keystore.
## 1.0.1+1
- at_persistence_spec version changes
## 1.0.1
 - Documentation changes
## 1.0.0
- Initial version, created by Stagehand




