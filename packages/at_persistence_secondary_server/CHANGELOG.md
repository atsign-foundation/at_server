## 3.0.59
- fix: When checking namespace authorization, gracefully handle any malformed 
  keys which happen to be in the commit log for historical reasons
## 3.0.58
- fix: Modify "lastCommittedSequenceNumberWithRegex" to return highest commitId among enrolled namespaces
## 3.0.57
- fix: Refactor commit log keystore to optimize memory usage
## 3.0.56
- fix: Refactor Hive keystore to optimize memory usage
- fix: Apply Utf7.decode function to decode the keys and atSigns containing emojis.
- feat: add skipCommit flag to keystore implementation which enables skipping commit log for put/create/remove.
## 3.0.54
- fix: Add NotificationType.Self in read and write methods of at_notification.dart
## 3.0.53
- feat: Introduced self notification type in enum for apkam enrollment
- chore: upgraded at_commons to 3.0.50 and at_utils to 3.0.14
## 3.0.52
- feat: Add new encryption metadata fields to core persistence classes
## 3.0.51
- feat: Extend sanity-checking of server-side commitLog upon startup
## 3.0.50
- fix: AtMetaData.fromJson now preserves null values for ttl, ttb and ttr
- test: Add '==' & hashCode to AtMetaData in order to be able to test equality
- test: Added tests which verify JSON round-tripping of AtMetaData objects
- refactor: Deprecate at_metadata_adapter; extract the 'to' and 'from' commons Metadata methods from there into the AtMetaData class itself
## 3.0.49
- fix: AtData.toJson() now works when the key is null
## 3.0.48
- fix: Ensure HiveKeystore's metaDataCache's keys are in lower case
## 3.0.47
- feat: conform to at_persistence_spec 2.0.11
## 3.0.46
- fix: AtMetadata.version does not update on the update of a key
## 3.0.45
- fix: Introduce "isScheduled" method in "AtCompactionService" to know if the compaction job is running
## 3.0.44
- fix: Refactor AtCompaction job
## 3.0.43
- fix: Fetch only commit entries with 'null' commit-id for uncommitted entries in at_client persistence
## 3.0.42
- fix: rollback keystore delete KeyNotFoundException
## 3.0.41
- fix: store actual keys in hive keystore metadata cache instead of encoded keys
- feat: throw KeyNotFoundException if key to be removed is not present in keystore
## 3.0.40
- feat: Refrain adding local keys to commit log.
## 3.0.39
- fix: lastSyncedEntry to accept signing private key
## 3.0.38
- fix: Revert sync of signing keys and 'statsNotificationId'
## 3.0.37
- fix: skip commit id for the 'statsNotificationId'
## 3.0.36
- fix: skip commit id and sync for signing keys
- fix: dart analyzer issues
- chore: upgrade third party dependencies
## 3.0.35
- fix: Randomize the cron job's start interval
- fix: Reduce the default notification expiry duration
## 3.0.34
* fix: Reverted dependency on 'meta' package to ^1.7.0 as flutter_test package (currently) requires 1.7.0
## 3.0.33
- feat: added key validation to keystore put and create methods
- chore: upgraded at_commons version to 3.0.24
## 3.0.32
- Add 'encoding' to AtMetadata which represents the type of encoding
## 3.0.31
- Invalidate commit log cache on removing entry from commit log
## 3.0.30
- Enhance KeyNotFoundException to chain into exception hierarchy.
- Upgrade at_commons version to 3.0.20 to encrypt notify text
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




