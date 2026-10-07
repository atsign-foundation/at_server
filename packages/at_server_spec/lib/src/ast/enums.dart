/// Closed value sets used by AST nodes. Each value's [Enum.name] is its
/// wire spelling unless it declares a `wire` override.
library;

/// `:priority:` on `delete` and `notify`.
enum Priority { low, medium, high }

/// The `meta` / `all` projection on `lookup`, `plookup`, and `llookup`.
/// Absent (`null`) means a plain value lookup.
enum LookupOperation { meta, all }

/// `update` / `delete` on `notify` and `notify:all`.
enum NotifyOperation { update, delete }

/// `:messageType:` on `notify` and `notify:all`.
enum MessageType { key, text }

/// `:strategy:` on `notify`.
enum NotifyStrategy { all, latest }

/// `signingAlgo:` on `pkam`.
enum SigningAlgo {
  rsa2048('rsa2048'),
  eccSecp256r1('ecc_secp256r1'),
  mldsa65('mldsa65');

  final String wire;
  const SigningAlgo(this.wire);
}

/// `hashingAlgo:` on `pkam`.
enum HashingAlgo { sha256, sha512 }

/// The `enroll:<operation>` sub-command.
enum EnrollOperation {
  request,
  approve,
  deny,
  revoke,
  listns,
  infons,
  list,
  fetch,
  unrevoke,
  delete,
  update,
}

/// The `otp:<operation>` sub-command.
enum OtpOperation { get, put }

/// The `keys:<operation>` sub-command.
enum KeysOperation { put, get, delete }

/// The optional visibility segment on `keys`.
enum KeysVisibility { public, private, self }

/// The `config:block:<operation>` sub-command.
enum BlockOperation { add, remove, show }

/// The `config:<operation>:<configNew>` sub-command.
enum ConfigSettingOperation { set, reset, print }

/// The optional `info:<mode>`.
enum InfoMode { brief, mtls, mtlsbrief }

/// The optional `stream:<operation>`.
enum StreamOperation { init, send, receive, done, resume }
