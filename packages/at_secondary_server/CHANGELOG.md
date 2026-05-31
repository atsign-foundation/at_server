# 3.14.0

- refactor: the persistence layer is now wired through the new
  `AtPersistenceFactory` injected into `AtSecondaryServerImpl`,
  replacing direct `*.getInstance()` calls in the bootstrap path
  (`_initializePersistentInstances`, `start`, `stop`).
- refactor: every `getInstance()` call onto the legacy persistence
  singletons has been removed from `lib/`. Verb handlers
  (`from`, `cram`, `lookup`, `pol`, `proxy_lookup`, `config`,
  `sync_progressive`) take their needed `AtCommitLog` and/or
  `AtAccessLog` via constructor; `DefaultVerbHandlerManager`
  threads them in. `metrics_impl` reads from `atServer.commitLog`,
  `atServer.accessLog`, `atServer.secondaryKeyStore`.
  `StatsNotificationService.schedule()` takes its `AtCommitLog`
  parameter rather than fetching it lazily.
  `SecondaryUtil.saveCookie` takes the `AtKeyValueStore` parameter.
- refactor: `AbstractVerbHandler.keyValueStore` and
  `DefaultVerbHandlerManager.keyValueStore` are now typed
  `AtKeyValueStore<String, AtData, AtMetaData?>` rather than a
  raw, un-parameterised keystore type. This surfaced and fixed
  a set of latent
  nullability gaps in the verb handlers that the raw type had been
  masking: unchecked `get()` results bound to a non-null `AtData`,
  `String?` keys passed into `get` / `remove` / `put`, and a
  `bool?` metadata field (`isCascade`) used directly as a condition.
- chore: `_accessLog` field on `AtSecondaryServerImpl` is now
  publicly named `accessLog`.
- chore: `DefaultVerbHandlerManager`'s constructor now takes
  `commitLog` and `accessLog` parameters (placed before the trailing
  `atSign` positional). External consumers that construct it
  directly will need to pass these.
- test: `test_utils.dart`'s `verbTestsSetUp` / `verbTestsTearDown`
  now drive a `HiveAtPersistenceFactory` instead of calling the
  per-singleton `getInstance()` paths. The `atServer.<field> = …`
  injection seam is preserved.
- refactor: `AtConfig` (block-list configuration) moves here from
  `at_persistence_secondary_server` and now lives at
  `package:at_secondary/src/config/at_config.dart`. The class is
  fully backend-agnostic — constructor takes an `AtKeyValueStore`
  (not an `AtCommitLog`), reads / writes go through the abstract
  keystore, and writes pass `skipCommit: true` so block-list state
  no longer bumps the local `commitId`. Callers in
  `from_verb_handler` and `config_verb_handler` updated; the
  construction signature is now `AtConfig(keyStore, atSign)`.

# 3.13.1

- fix: log the offending rawVerb and command when
  `InboundCommandValidator.validate` throws an InvalidSyntaxException

# 3.13.0

- feat(deps): Take up at_commons ^5.10.0 to pick up new command (verb) syntax

# 3.12.0

- perf: substantial reduction in per-request heap allocations on the
  inbound, verb-dispatch and update paths (regex literals hoisted to
  `static final`; `logger.info(...)` sites guarded by `isLoggable`;
  `Uint8List` per-chunk copy replaced with shared sentinel in
  `StreamableByteBuffer`; `DateTime.now().toUtc()` →
  `DateTime.timestamp()` / `.millisecondsSinceEpoch`;
  `InboundCommandValidator` decodes only a 256-byte prefix and uses
  `indexOf` instead of `split(':')`;
  `AbstractUpdateVerbHandler._unsetOrRetainMetadata` rewritten as a
  field-by-field in-place merge — drops three per-update Map
  allocations; `(Mutex,int)` record replaced with mutable
  `MutexRef` holder; unused `AtData()` allocation removed)
- fix: `MonitorVerbHandler.MapForClient` uses `?.` for `ttr`/`ttl`/`ttb`
  to match its neighbours, so notifications without `atMetadata` no
  longer blow up
- fix: auth-error message unified across the validator and
  `AbstractVerbHandler.processInternal` — both now report
  `Command cannot be executed without auth`
- fix: config-driven cert reload (`config:set:checkCertificateReload=true`)
  now uses a 3-second force-restart fast path instead of waiting up to
  30 s for graceful drain
- chore: `DART_VM_OPTIONS` switched to comma-separated form so the Dart
  AOT runtime parses multiple flags correctly

# 3.11.3

- feat: tweak the garbage collection runtime flags

# 3.11.2

- feat: log value of Platform.executableArguments on startup

# 3.11.1

- feat: http handling tweak for more consistent behaviour for access via proxy 
  and direct access
- feat: log the values of DART_VM_OPTIONS during startup

# 3.11.0

- feat: make presentation of client certificates configurable for 
  atServer-to-atServer communication
- feat: dart runtime flags for more aggressive heap management
- fix: tighten FromVerbHandler hostname checking
- fix: immediately delete challenge-response secrets upon success in cram,
  pkam & pol handlers
- refactor: improve readability of cram verb handler digest checking
- feat: remove expired notifications on startup

# 3.10.3

- chore: remove obsolete configuration
- fix: set `AtNotifcation.defaultTtl` to value of config 
  `notificationExpiryInMins`

# 3.10.2

- fix: enforce consistent handling of notification expirations

# 3.10.1

- Defensive code to handle bad data in some very old atServers

# 3.10.0

- Overhaul notification handling
  - Bug-fixes
    - Check if notification has expired before sending to remote atServer
    - Ignore notifications from another atServer if we've already got them
      stored
    - Ignore notifications from another atServer if they have already expired
  - Enhancements
    - Removed complicated old internal machinery, replaced with streams-based
      approach
    - Made MonitorVerbHandler consistent with other verb handlers by ensuring
      that only one is needed, and the connection-to-monitor-config state is
      held in a map
    - Did various refactoring and cleanup of other code encountered
    - Improved performance in various places, mostly related to fetching
      notifications

# 3.9.4

 - build(deps): Add pubspec.lock and use ^ in pubspec.yaml

# 3.9.3

- fix: only allow `enroll:deny` to operate on `pending` enrollments

# 3.9.2

- fix: remove call to `flush` from `BaseSocketConnection.write()` thus
  preventing a race which was triggering a `StreamSink is bound to a stream`
  StateError

# 3.9.1

- chore: deal with breaking changes introduced by at_commons 5.8.0

# 3.9.0

- feat: Add `info` subcommands `info:mtls` and `info:mtlsbrief`

# 3.8.0

- feat: When available, present mtls client certs to other atServers, rather
  than presenting the server's server certs, which we can no longer depend
  on to have the client bit.

# 3.7.2

- fix: improved memory usage and error handling in StatsNotificationService. 
  Fixes a minor bug in StatsNotificationService which would only occur when 
  running an atServer on a development machine which is put to "sleep" for a 
  while.
- refactor: Removed unnecessary instance variable from StatsNotificationService

# 3.7.1
- feat : added `stats:16` for a summary of number of inbound connections by 
  type (self, other, anon) and `stats:17` for a detailed report on all 
  inbound connections including atSigns, time established, last accessed time.
- fix: better idle time defaults for inbound and outbound connections, 
  authenticated and unauthenticated 
- refactor: removed a bunch of singletons

# 3.7.0
- fix: better idle time defaults for inbound and outbound connections, 
  authenticated and unauthenticated 

# 3.6.0
- feat: Expanded http support

# 3.5.3
- fix: Set the trusted cacert path for AtSecondaryFinder

# 3.5.2
- fix: Prevent OutboundClient from creating new socket connections unnecessarily

# 3.5.1
- build: update version number to 3.5.1

# 3.5.0
- fix: scan verb now using AbstractVerbHandler.isAuthorized for namespace
  access checks by @gkc in https://github.com/atsign-foundation/at_server/pull/2276
- feat: Created Docker ephemeral enviroment for standalone atPlatform by 
  @cconstab in https://github.com/atsign-foundation/at_server/pull/2288
- feat: Update Dart version to 3.8.0 for Ephemeral Environment Dockerfile by 
  @cconstab in https://github.com/atsign-foundation/at_server/pull/2294
- feat: per-enrollment data by @gkc in https://github.
  com/atsign-foundation/at_server/pull/22

# 3.4.1
- fix: potential bugs handling atSigns which end in `data`

# 3.4.0
- feat: immutable records
  - When `immutable` is set in metadata, then the record may not
    subsequently be changed via the `update` verb.
  - When `immutable` is set in metadata, then the record may not be deleted
    via the `delete` verb unless the new `force` parameter is set
    - However, data which has been cached by the recipient is always 
      deletable by that recipient
# 3.3.0
- feat: Add support for "atServer events" - starting with the 
  `AtSignPKChangedEvent`. atServer events are stored in a newly reserved 
  namespace called `__atserver` to which all clients will have read access 
  but not write access - creating new atServer events is solely an atServer 
  responsibility. Clients will typically fetch events when they initially 
  connect, and will then handle appropriately (for example: store the event 
  information locally; handle it; mark as processed locally.) 
  Clients should keep a marker for the latest event they have 
  fetched so that when they restart they do not re-process past events. 
  Newly-created clients should set their initial marker to
  microsecondsSinceEpoch so that they do not process past events unnecessarily.
# 3.2.0
- feat: Added WebSocket support for inbound connections
# 3.1.1
- fix: Store "publicKeyHash" value in the keystore
- fix: add limit param in SyncProgressiveVerbHandler
- build[deps]: Upgraded the following package:
  at_commons to v5.1.2
# 3.1.0
- feat: sync skip deletes until changes 
- fix: Enable persistence of the Initialization Vector for "defaultEncryptionPrivateKey" and "selfEncryptionKey" in
  the APKAM flow.
- build[deps]: Upgraded the following package:
  - at_commons to v5.1.0
  - at_persistence_secondary_server to v3.1.0
# 3.0.52
- build[deps]: Upgraded the following package:
  - at_commons to v5.0.2
  - at_chops to v2.2.0
  - meta to v1.16.0
  - test to v1.25.9
  - args to v2.6.0
  - at_persistence_secondary_server to v3.0.66 to consume publicKeyHash changes.
## 3.0.51
- feat: Introduce option to unrevoke revoked enrollments
- feat: Introduce option to delete enrollments that are denied/revoked
- fix: LatestCommitEntryOfEachKey metric fixed to return commit log entries till last commitID instead of default limit 25.
- feat: Implement an option to automatically expire APKAM keys after a specified duration
- build[deps]: Upgraded the following package:
  - at_commons to v5.0.0
  - at_utils to v3.0.19
  - at_chops to v2.0.1
  - at_lookup to v3.0.49
  - at_persistence_secondary_server to v3.0.64
  - at_server_spec to v5.0.2
## 3.0.50
- fix: Enhance namespace authorisation check to verify when namespace has a period in it
- feat: Enable expiration of APKAM keys based on the specified duration.

## 3.0.49
- feat: Enforce superset access check for approving apps
- fix: respect isEncrypted:false if supplied in the notify: command, and 
  ensure that the correct value is always transmitted onwards
- fix: info verb no longer lists "beta" features which are now live
- fix: in MonitorVerbHandler, add "sharedKeyEnc" to the metadata to propagate the sharedEncryptedKey in
  notifications from the server to the client.
- build[deps]: Upgraded the following package:
  - at_persistence_secondary_server to v3.0.63

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
