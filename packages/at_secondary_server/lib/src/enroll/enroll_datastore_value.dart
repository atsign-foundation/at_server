import 'package:at_commons/at_commons.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';

part 'enroll_datastore_value.g.dart';

/// Represents attributes for APKAM enrollment data
@JsonSerializable()
class EnrollDataStoreValue {
  late String sessionId;
  late String appName;
  late String deviceName;

  // map for representing namespace access. key will be the namespace, value will be the access
  // e.g {'wavi':'r', 'buzz':'rw'}
  Map<String, String> namespaces = {};
  late String apkamPublicKey;
  EnrollRequestType? requestType;
  EnrollApproval? approval;
  String? encryptedAPKAMSymmetricKey;
  Duration apkamKeysExpiryDuration = Duration(milliseconds: 0);

  /// Opaque per-APKAM metadata stored by the client (WP-SS).
  /// The server treats this as an opaque JSON map and returns it verbatim in
  /// enroll:listns responses. The enrollment's single (APKAM-signed) key
  /// package lives under metadata['keyPackage'] by convention (1:1:1 — no
  /// format-keyed map).
  Map<String, dynamic>? metadata;

  /// The signing algorithm of [apkamPublicKey] — `rsa2048` (legacy default) or
  /// `mldsa65` (PQ). Recorded so PKAM verification can be record-authoritative.
  String? signingAlgo;

  /// The client-composed value published at
  /// `public:_apsk.<enrollmentId>.a.__e@<atSign>` when this enrollment is
  /// approved, carried on `enroll:request` as `EnrollParams.apsk`.
  ///
  /// Opaque, exactly like [metadata]: the server stores it and JSON-encodes it
  /// into the record it publishes, and has no opinion on the contents. It is
  /// deliberately NOT composed from [apkamPublicKey] and [signingAlgo] — PKAM
  /// verification reads this record, so `_apsk` is a client-side artefact and
  /// the format belongs to the side that reads it.
  ///
  /// Null means no `_apsk` is published for this enrollment at all. The
  /// enrollee publishes its own from its own connection, or goes without.
  ///
  /// Why the server writes it at all, given it never reads it: `_apsk` accepts
  /// writes only from its own enrollment's connection, and at approval that
  /// connection has never existed. The approver needs the record in place
  /// immediately — it verifies the enrollee's key package against it and signs
  /// signing-chain links over it — so the server is the only party that can
  /// put it there in time.
  Map<String, dynamic>? apsk;

  /// The **bare** `_apsk` value — an RSA public key string exactly as the
  /// record has always carried it — carried on `enroll:request` as
  /// `EnrollParams.apskLegacy` and published verbatim, NOT JSON-encoded.
  ///
  /// It exists because every deployed `_apsk` consumer base64-decodes the
  /// value as an RSA key, so a JSON one fails their parse. That is fail-closed
  /// but service-breaking for anything already running, so a plain-legacy
  /// enrollment publishes the shape they expect through the same verb every
  /// other enrollment uses.
  ///
  /// Mutually exclusive with [apsk], on the wire and at rest: one record
  /// publishes one value, and a record holding both would make the published
  /// value depend on a precedence rule nobody stated. The request that carries
  /// both is refused, and an `enroll:update` that sets either one clears the
  /// other.
  String? apskLegacy;

  /// The enrollment that APPROVED this one — its parent — or null when
  /// nothing did.
  ///
  /// Parenthood is the approval edge, and revocation cascades along it to any
  /// depth: an enrollment holding `__manage` that admits others, and is then
  /// revoked as compromised, must not leave everything it admitted
  /// authenticating. [EnrollmentManager.descendantsOf] walks this edge and
  /// no other.
  ///
  /// Set from the connection on `enroll:approve`, never from the request, so
  /// an approver cannot name someone else as the admitting party. A retrofit
  /// COPIES its predecessor's value rather than naming the predecessor: the
  /// successor is the same principal re-keyed, so it stands where its
  /// predecessor stood as a SIBLING of what it replaced, and whoever admitted
  /// the predecessor admitted this. Null there would make a retrofit an
  /// escape hatch from the cascade.
  ///
  /// Null on two origins, each deliberately:
  ///
  /// * an enrollment approved over a connection carrying no enrollment id.
  ///   There is no enrollment to revoke, and "revoking the owner" is not a
  ///   thing;
  /// * every enrollment written before this field existed. The edge is
  ///   forward-only and cannot be reconstructed: nothing recorded an approver.
  String? parentEnrollmentId;

  /// The enrollment this one REPLACED in a retrofit — its predecessor — or
  /// null for every other origin.
  ///
  /// Not a parenthood edge, and revocation does not cascade along it. A
  /// retrofit REPLACES: the successor is the same principal re-keyed, not a
  /// new one derived from it, so revoking the superseded form must not take
  /// the credential that supersedes it — an operator retiring an old key
  /// would otherwise kill the device's current one. What this edge is for:
  /// the once-off rule, which refuses to retrofit a successor again without
  /// an approver; the retrofit cap, which arms on the successor's first
  /// authentication and needs to know what it replaced; and tooling, which
  /// finds a whole sibling set by it when the siblings' parent is null.
  String? retrofitPredecessorEnrollmentId;

  /// When this enrollment settled the retrofit cap on the enrollment it
  /// replaced — either by arming it, or by finding there was nothing left to
  /// arm it on. Null while the question is still open.
  ///
  /// Not a record of "a cap was written": a predecessor that has already been
  /// deleted stamps this too, because otherwise every later connection
  /// re-walks a lookup for something that is never coming back. A cap that is
  /// DECLINED does not stamp — a decline is a judgement about state that can
  /// change, so it is re-made rather than frozen.
  ///
  /// The cap is armed by the successor's FIRST PKAM authentication rather than
  /// at the moment the server stores it. Storing the record proves only that
  /// the server wrote it: the successor's APKAM private half lives client-side,
  /// so a keyfile write that fails, a read-only file, or a process that dies
  /// before the flush all leave the successor existing on the server and
  /// nowhere else -- with a clock already running on the only credential that
  /// still works. An authentication on a connection the successor opened is
  /// what proves the private half survived and is usable.
  ///
  /// Stamped rather than a bare flag because the cap RE-ARMS: each sibling
  /// replacing the same predecessor pushes the deadline out afresh, so a
  /// predecessor retires one grace period after the LAST of its replacements
  /// authenticates. Only the FIRST authentication of any one successor arms.
  /// Without that, every reconnect would extend the predecessor's life by a
  /// whole grace period and it would never retire at all.
  DateTime? predecessorCapArmedAt;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  /// A "root" enrollment: read-write on every namespace AND on `__manage`.
  ///
  /// This is what the first (CRAM-path) enrollment is auto-granted, and what a
  /// later enrollment must be given explicitly to hold full privileges.
  /// Holding `*` alone does not qualify, and neither does `__manage` alone.
  ///
  /// Full privilege rather than the ability to approve, because those differ
  /// and the difference decides whether an atSign can recover. Approving is
  /// checked per namespace against what the approver itself holds, so an
  /// enrollment with `__manage` but not `*` can admit new enrollments and can
  /// never admit one carrying `*` — it keeps an atSign running but cannot
  /// restore a root to it. That comparison covers `__manage` itself, so an
  /// approver holding `__manage:r` confers no more than `__manage:r` either.
  bool get isRootEnrollment =>
      EnrollmentAccess.allowsWrite(
          namespaces[EnrollmentConstants.allNamespaces]) &&
      EnrollmentAccess.allowsWrite(
          namespaces[EnrollmentConstants.enrollManageNamespace]);

  factory EnrollDataStoreValue.fromJson(Map<String, dynamic> json) =>
      _$EnrollDataStoreValueFromJson(json);

  Map<String, dynamic> toJson() => _$EnrollDataStoreValueToJson(this);

  Map<String, dynamic> toJsonExtended() {
    final m = toJson();
    m['status'] = approval?.state;
    m['namespace'] = m['namespaces'];
    return m;
  }

  /// The roster view of this enrollment: everything an administrator needs to
  /// render it, audit it and decide what to ask of it, and none of the key
  /// material that would let one USE it.
  ///
  /// Built as an explicit field set rather than [toJsonExtended] with the
  /// secrets removed. Blanking would make a redacted field indistinguishable
  /// from an enrollment that never had one, and it puts the burden on
  /// whoever adds the NEXT secret-bearing field to remember to strike it
  /// here. A field added to the record is absent from this view until
  /// somebody adds it deliberately, which is the direction that fails safe.
  ///
  /// Omitted, and why: `encryptedAPKAMSymmetricKey` and `apsk`/`apskLegacy`
  /// are the wrapped key material an approver needs and nobody else can use;
  /// `apkamPublicKey` and `metadata` (which carries the key package) identify
  /// the credential itself; `sessionId` names the connection the request
  /// arrived on. None is needed to decide whether an enrollment should stand.
  Map<String, dynamic> toJsonRoster() => <String, dynamic>{
        'appName': appName,
        'deviceName': deviceName,
        'namespaces': namespaces,
        // `namespace` is the alias toJsonExtended emits; kept so a roster
        // entry reads the same either side of the redaction.
        'namespace': namespaces,
        'requestType': requestType?.name,
        'approval': approval,
        'status': approval?.state,
        'apkamKeysExpiryInMillis': apkamKeysExpiryDuration.inMilliseconds,
        if (signingAlgo != null) 'signingAlgo': signingAlgo,
        if (parentEnrollmentId != null)
          'parentEnrollmentId': parentEnrollmentId,
        if (retrofitPredecessorEnrollmentId != null)
          'retrofitPredecessorEnrollmentId': retrofitPredecessorEnrollmentId,
        if (predecessorCapArmedAt != null)
          'predecessorCapArmedAt': predecessorCapArmedAt!.toIso8601String(),
      };
}

class EnrollApproval {
  String state;

  EnrollApproval(this.state);

  EnrollApproval.fromJson(Map<String, dynamic> json) : state = json['state'];

  Map<String, dynamic> toJson() => {
        'state': state,
      };

  @override
  String toString() {
    return '{state: $state}';
  }
}

enum EnrollRequestType { newEnrollment, changeEnrollment }
