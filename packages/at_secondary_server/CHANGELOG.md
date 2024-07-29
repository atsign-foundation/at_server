## 3.0.49
- feat: Enforce superset access check for approving apps
- fix: respect isEncrypted:false if supplied in the notify: command, and 
  ensure that the correct value is always transmitted onwards
- fix: info verb no longer lists "beta" features which are now live
- fix: in MonitorVerbHandler, add "sharedKeyEnc" to the metadata to propagate the sharedEncryptedKey in
  notifications from the server to the client.
## 3.0.48
- feat Add expiresAt and availableAt params to notify:list response

## 3.0.47
- feat: Introduced a dedicated namespace for storing OTPs
- feat: allow a ttl to be set for a semi-permanent passcode (spp)

## 3.0.46
- fix: Default OTP expiry value remains unchanged for the subsequent "otp:" requests
- fix: Fix the handling of enrollment self-notifications

## 3.0.45
- fix: Update the response format of the "enroll:fetch" to match with "enroll:list" for consistency
- feat: enroll:revoke now has an optional "force" flag to allow current 
  connection to revoke its own enrollment
- fix: Fixed bug in delivery of notifications to APKAM Monitors

## 3.0.44
- fix: otp authentication check
- build[deps]: Upgraded the following packages:
  - at_commons to v4.0.8
  - at_server_spec to v5.0.1
  - at_lookup to v3.0.47
- feat: Add enroll:fetch to fetch the enrollment details.
- fix: Added validation to ensure a new enrollment request does not contain a duplicate combination of appName and
  deviceName.

## 3.0.43
- fix: ensure all connection writes are awaited

## 3.0.42
- feat: allow filtering of requests in EnrollVerbHandler using enrollment
  approval status
- feat: authorization changes for keys with no namespace and for reserved keys
- build(deps): dependabot changes
- fix: Improve socket handling for better server resilience
- fix: Ensure cached keys like 'cached:public:publicKey' are not considered 
  protected keys and can thus be deleted

## 3.0.41
- fix: bug in access control for otp put
## 3.0.40
- build[deps]: Upgraded the following packages: 
   - at_chops to 2.0.0
   - at_server_spec: to 4.0.1
- feat: at_server_spec: BREAKING: make AtConnection generic; make it more Dart-idiomatic
- feat: Do NOT add delete entries in commit log when expired keys are deleted
- feat: Introduce config to trigger skip_commits_for_expired_keys
- fix: Add enrollment "appName", "deviceName" and "namespace" to notification for apps listening on enrollment requests 
- fix: Return encryptedAPKAMSymmetricKey in enroll list
## 3.0.39
- build[deps]: Upgraded the following packages:
  - at_commons to v4.0.0
  - at_utils to v3.0.16
  - at_lookup to v3.0.44
  - at_chops to v1.0.7
  - at_persistence_secondary_server to v3.0.60
  - at_server_spec to 3.0.16
- feat: Improve enrollment usability by adding ability to create multi-use 'semi-permanent' enrollment passcodes
## 3.0.38
- Introduce a new config key to store an atsign's blocklist
## 3.0.37
- fix: In the `SyncProgressiveVerbHandler.prepareResponse` method, gracefully 
  handle any malformed keys which happen to be in the commit log for
  historical reasons
- build: Take up at_persistence_secondary_server version 3.0.59 which
  includes a similar fix when checking namespace authorization in the
  `CommitLogKeyStore._isNamespaceAuthorised` method
## 3.0.36
- fix: Implement notify ephemeral changes - Send notification with value without caching the key on receiver's secondary server
- feat: Implement AtRateLimiter to limit the enrollment requests on a particular connection
- fix: Upgraded at_commons to 3.0.56
- fix: Enable client to set OTP expiry via OTP verb
- fix: Prevent reuse of OTP
- fix: Modify sync_progressive_verb_handler to filter responses on enrolled namespaces if authenticated via APKAM 
## 3.0.35
- chore: Upgraded at_persistence_secondary_server to 3.0.57 for memory optimization in commit log
- feat: APKAM keys verb implementation
- feat: Implementation changes for latest APKAM specification
- Allow lookup verb for only authorized namespaces when authenticated via APKAM
- feat: Use at_lookup's CacheableSecondaryAddressFinder
- feat: Use latest at_lookup 3.0.40 which does retries in the event of 
  transient atDirectory connection failures while looking up atServer addresses
## 3.0.34
- chore: Upgraded at_persistence_spec to 2.0.14
- chore: Upgraded at_persistence_secondary_server to 3.0.56
## 3.0.33
- feat: Modified monitor verb handler to process self notification for APKAM
- chore: Upgraded at_persistence_secondary_server to 3.0.55 for memory optimization
- chore: Upgraded at_server_spec to 3.0.13, at_commons to 3.0.50 and at_utils 3.0.14
- feat: APKAM enroll verb handler implementation
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
