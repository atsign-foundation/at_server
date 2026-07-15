/// Single source of truth for PQ key-record naming — used by [PqKeyManager],
/// the server's `_protectedKeys` set, and tests.
///
/// Local-only records live under the `local:` namespace: never commit-logged
/// (see `hive_at_commit_log.dart`), so never synced, and not addressable via
/// update/delete/lookup/scan verbs. This is deliberately not `privatekey:` —
/// that prefix is a closed enumeration validated by at_commons' key-type
/// regexes — nor a bare self key (`@atSign:name@atSign`), which IS
/// commit-logged and syncs to enrolled clients, leaking PQ secret material.
///
/// Only [pqXwingCertNamePart]/[pqXwingCertName] are peer-fetchable (`public:`);
/// every other record is `local:` and never leaves this server.
library;

const String pqXwingCertNamePart = 'pq_xwing_cert';

String pqSigningSecretKeyName(String atSign) =>
    'local:pq_signing_secretkey$atSign';

String pqSigningPublicKeyName(String atSign) =>
    'local:pq_signing_publickey$atSign';

String pqXwingSecretKeyName(String atSign) => 'local:pq_xwing_secretkey$atSign';

String pqXwingPublicKeyName(String atSign) => 'local:pq_xwing_publickey$atSign';

String pqXwingSecretKeyPrevName(String atSign) =>
    'local:pq_xwing_secretkey_prev$atSign';

String pqXwingCertPrevName(String atSign) => 'local:pq_xwing_cert_prev$atSign';

String pqXwingCertName(String atSign) =>
    'public:$pqXwingCertNamePart$atSign';
