## 3.0.33
- feat: modified monitor verb handler to process self notification for apkam
- chore: upgraded at_persistence_secondary_server to 3.0.53, at_server_spec to 3.0.13, at_commons to 3.0.50 and at_utils 3.0.14
- feat: apkam enroll verb handler implementation
## 3.0.32
- fix: Enhance stats verb to return latest commitEntry of each key
- chore: Ignore melos files
- chore: Uptake at_commons v3.0.46 which fixes failure of server when atSign
  has emoji with variation selector
- chore: Uptake at_utils v3.0.13 which enables logging to StandardError
- feat: Retain current inbound pool management logic, but be a **LOT** less 
  aggressive when closing idle **authenticated** inbound connections
## 3.0.31
- feat: Introduce clientId, appName, appVersion and platform to distinguish requests from several clients in server logs.
## 3.0.30
- fix: When metadata attributes are not set, merge the existing metadata attributes
- fix: When metadata attributes are explicitly set to null, reset the metadata
## 3.0.29
- fix: Check if connected atSign is authorized to send notifications
- feat: support new pkam verb syntax allowing for authentication using multiple signing and hashing algorithms
- feat: Support additional encryption metadata for encryption future-proofing
## 3.0.28
- fix: Refactor notify_verb_handler.dart to increase readability of code
- refactor: Add AtCacheManager so that we can handle all caching operations in one place
- refactor: Move cache-related operations from LookupVerbHandler and ProxyLookupVerbHandler into AtCacheManager
- test: Added unit tests covering full behaviour of LookupVerbHandler and ProxyLookupVerbHandler including caching
- feat: Handle resets of other atSigns by detecting changes to their public encryption keys
- test: Added unit tests covering behaviour when public encryption keys changes detected
- test: Added unit tests covering behaviour of the CacheRefreshJob
- fix: Cleaned up exception handling in a few places
- fix: Ensure no commit entries are left behind un-synced
## 3.0.27
- Upgrade at_persistence_secondary_server version to 3.0.46 for at_compaction
## 3.0.26
- Upgrade at_persistence_secondary_server version to 3.0.43
- Upgrade at_lookup version to 3.0.33
- Upgrade at_commons version to 3.0.32
## 3.0.25
- Upgrade at_persistence_secondary_server version to 3.0.40
- Upgrade at_commons version to 3.0.28
## 3.0.24
- chore: upgrade version of persistence_secondary, at_commons and at_lookup
- feat: Introduce Notify fetch verb
## 3.0.23
- fix: fixes to optimize the memory usage
- feat: Return error codes and JSON encode the error response
## 3.0.22
- feat: Add key validations
- feat: Enhance from verb to have client config
- fix: Handle invalid AtKey exception on server
## 3.0.21
- fix: invalidate commit log cache on key deletion
- feat: remove malformed keys on server startup
- fix: inbound connection pool test flakiness
- feat: encode the new line characters in the public key data
## 3.0.20
- fix: Bypass cache rename fix
- feat: Set isEncrypted to true when notify text message is encrypted.
- Update the at_lookup version to 3.0.28
- Update the at_persistence_secondary_server version to 3.0.30
## 3.0.19
- Upgrade at_persistence_secondary_server version to 3.0.28 which replaces null commitId(s) with hive internal key(s) on server startup
- Enhance scan verb to display hidden keys when showHiddenKeys is set to true
## 3.0.18
- Fix compaction when null commitId
- Fix issues in notifications and add tests
- No-op change to trigger build run
- Fix HandshakeException handling
## 3.0.17
- FEAT: Support to bypass cache
## 3.0.16
- Significant decreases in inter-at-sign notification latency from 1 to 6 seconds to 5 to 100 milliseconds
## 3.0.15
- Info verb now supports 'info:brief' usage
## 3.0.14
- Notify verb handler changes for shared key and public key checksum in metadata
- Inbound connection management improvements
- Update persistence version for hive upgrade
## 3.0.13
- Changes to add responses to queue from last in outbound message listener
- Uptake at_lookup version change for increase timeout for outbound connection
- Added compaction statistics to stats verb handler
- update verb and update meta verb handler changes for shared key and public key checksum in metadata
## 3.0.12
- Throw AtTimeoutException when connection timeouts
- Throw AtConnectException for error responses and unexpected responses
## 3.0.11
- Changes to support reset of ttb and ttl
## 3.0.10
- Workaround for signing private key not found issue.
## 3.0.9
- Enhance commit log compaction service.
- Notification expiry feature
## 3.0.8
- reduce compaction interval to 12 hrs
- compaction delete bug fix
## 3.0.7
- Commit log compaction
- Commit log will use in memory hive box. Other keystores will use lazy boxes.
## 3.0.6
- Rollback hive lazy box
## 3.0.5
- Uptake latest persistence - remove compaction strategy
## 3.0.4
- Fix NPE in commit log keystore.
## 3.0.3
- Change Hive box type to lazy box
## 3.0.2
- Remove logging of binary data
## 3.0.1
- Fix null aware issue in sync verb handlers
## 3.0.0
- Sync Pagination feature
## 2.0.7
- Reinitialize hive boxes on certs reload
## 2.0.6
- Fix for hive box closed issue
## 2.0.5
- Logs for hive box closed issue
## 2.0.4
- Last notification time support in Monitor
## 2.0.3
- Support for stream verb resume
