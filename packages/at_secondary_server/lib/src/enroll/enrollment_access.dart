/// The access level an enrollment holds over a namespace, and the two
/// questions the server ever asks of one.
///
/// The level arrives as client-supplied JSON on `enroll:request` and is
/// stored verbatim on the enrollment record, so every reader is looking at a
/// string a client chose. Until these existed, each reader compared that
/// string exactly — `access == 'rw'` — in ten places, and the sole exception
/// (the retrofit escalation check) read it as a SET of letters. The two
/// disagreed about the same string in the same request.
///
/// Exact comparison is not merely inconsistent, it is inconsistent in both
/// directions at once. For the powers a grant CONFERS it fails closed, so a
/// grant spelled `wr` yields an enrollment that can do nothing. For the
/// questions of the form "is this enrollment powerful enough that I need
/// authority over it" it fails OPEN, which is where the exposure is: a target
/// holding `__manage:wr` did not count as holding write on `__manage`, so a
/// read-only administrator was admitted to approve, revoke and delete it; and
/// a root spelled `{'*':'wr','__manage':'wr'}` did not count as a root, so
/// the guard that refuses to revoke an atSign's last root counted zero roots
/// and permitted the revoke that strands it.
///
/// So there are two rules here, and both are needed. [canonicalise] refuses a
/// spelling the server will not act on at the one place a grant is written,
/// so no new record can hold one. [allowsRead] and [allowsWrite] read the
/// letters as a set, so the records already on disk are read the same way by
/// every site rather than differently by each.
///
/// Reading a stored non-canonical grant as a letter set does WIDEN it: a
/// record holding `wr` could do nothing before and can read and write after.
/// That is the intent its author expressed, it is what the escalation check
/// already believed, and it is the direction that closes the fail-open
/// authority questions above — which is the half that can strand an atSign.
abstract final class EnrollmentAccess {
  /// Read-only over a namespace.
  static const String read = 'r';

  /// Read and write over a namespace.
  static const String readWrite = 'rw';

  /// The only two spellings the server will store.
  ///
  /// A raw literal set rather than a set built from the constants above: this
  /// is a wire vocabulary that clients and every other atServer
  /// implementation spell out, so it is pinned here and an intended change
  /// edits the pin.
  static const Set<String> canonicalSpellings = {'r', 'rw'};

  /// Returns [access] when it is a spelling the server acts on, else null.
  ///
  /// Refused rather than coerced. A grant is an authorisation decision, so a
  /// spelling the server does not recognise is a client that meant something
  /// this server cannot promise to honour — `wr`, `RW`, `rw ` and `rwx`
  /// alike. Telling the client is the only way it learns; storing a guess
  /// hands out an authority nobody asked for.
  static String? canonicalise(String? access) =>
      (access != null && canonicalSpellings.contains(access)) ? access : null;

  /// Whether [access] confers read over the namespace it is attached to.
  ///
  /// Null and empty confer nothing: an empty access level is not a grant, it
  /// is the absence of one.
  static bool allowsRead(String? access) => _has(access, 'r');

  /// Whether [access] confers write over the namespace it is attached to.
  static bool allowsWrite(String? access) => _has(access, 'w');

  static bool _has(String? access, String letter) =>
      access != null && access.contains(letter);
}
