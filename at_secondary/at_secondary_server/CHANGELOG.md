## 3.0.24
- chore: upgrade version of persistence_secondary, at_commons and at_lookup
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
