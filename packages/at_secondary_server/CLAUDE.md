# at_secondary_server — contributor notes

## Dependency injection (the "singletons battle", trunk 2026-06)

Verb handlers and their collaborators are **constructor-injected**, not reached
via `AtSecondaryServerImpl.getInstance()`. The seam is **`VerbHandlerContext`**
(`lib/src/server/verb_handler_context.dart`): one immutable holder of
server-scoped collaborators (`currentAtSign`, `responseManager`,
`exceptionHandler`, `streamManager`, `enrollmentManager`,
`statsNotificationService`, `secondaryAddressFinder`), built once in
`AtSecondaryServerImpl.start()` and passed through
`DefaultVerbHandlerManager._loadVerbHandlers()` to every handler via
`AbstractVerbHandler(keyStore, context)`.

- **Add a new shared collaborator** by adding a field to `VerbHandlerContext` —
  this touches only the two construction sites (`at_secondary_impl.dart` and
  `test/test_utils.dart`), not every handler. Do **not** add a new singleton.
- `OutboundClient` is injected too; it takes a narrow `cachePublicKey` callback
  (wired to `AtCacheManager.put`) rather than the whole cache manager, to break
  the genuine `OutboundClient ↔ AtCacheManager` dependency cycle (don't
  re-introduce a direct `AtCacheManager` dependency there).
- Response handlers receive `currentAtSign` + `exceptionHandler` from
  `DefaultResponseHandlerManager` (owned by the context).

## Deliberately-retained `getInstance()` reaches — do NOT "fix" these

A handful of `AtSecondaryServerImpl.getInstance()` reaches are intentional
composition-root access, not oversights (each is commented inline):

- **Late-bound server state** read at request time by early-built handlers:
  `notify_all` (`signingKey`, loaded asynchronously during startup) and `enroll`
  (`inboundConnectionManager.pool`, created after the context is built). These
  are not constructor-injectable.
- **Connection-lifecycle / metrics layer** (below the verb-handler DI seam):
  inbound connection `serverContext` (config, with a default fallback — the
  connection is constructed ~100× in tests), `InboundMessageListener`,
  `connection_metrics`, `stats_notification_service`, `outbound_connection_impl`,
  `at_certificate_validation`, and `StatsVerbHandler._inboundConnectionPool` (a
  late getter for the inbound pool, which is created after the handler is built —
  the other stats collaborators are constructor-injected and each `MetricProvider`
  takes only the dependency it needs). These operate on server-wide state by design.
- **Static-by-design shared state**: `AbstractUpdateVerbHandler._updateMutexes`
  (a per-key mutex registry deliberately shared across `UpdateVerbHandler` and
  `UpdateMetaVerbHandler`) and `_autoNotify` (process-wide runtime config toggled
  via `config:set`, mirroring `AtSecondaryConfig`).

`AtSecondaryServerImpl` itself remains the singleton composition root.
`AtSecondaryConfig` (all-static runtime config) was intentionally left as-is —
converting it is a separate effort.
