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

  // Namespace access: key is the namespace, value the access level.
  // e.g. {'wavi':'r', 'buzz':'rw'}
  Map<String, String> namespaces = {};
  late String apkamPublicKey;
  EnrollRequestType? requestType;
  EnrollApproval? approval;
  String? encryptedAPKAMSymmetricKey;
  Duration apkamKeysExpiryDuration = Duration(milliseconds: 0);

  /// Opaque per-APKAM metadata the client stores. The server keeps it as an
  /// opaque JSON map and returns it verbatim in `enroll:listns` responses. By
  /// convention the enrollment's single APKAM-signed key package lives under
  /// `metadata['keyPackage']`.
  Map<String, dynamic>? metadata;

  /// The signing algorithm of [apkamPublicKey]: `rsa2048` (the legacy
  /// default) or `mldsa65`. Recorded so PKAM verification is
  /// record-authoritative.
  String? signingAlgo;

  /// The client-composed value published at
  /// `public:_apsk.<enrollmentId>.a.__e@<atSign>` when this enrollment is
  /// approved, carried on `enroll:request` as `EnrollParams.apsk`.
  ///
  /// Opaque, exactly like [metadata]: the server stores it, JSON-encodes it
  /// into the record it publishes, and has no opinion on the contents. It is
  /// deliberately NOT composed from [apkamPublicKey] and [signingAlgo], since
  /// PKAM verification reads this record and `_apsk` is a client-side
  /// artefact whose format belongs to the side that parses it.
  ///
  /// Null means no `_apsk` is published for this enrollment at all.
  ///
  /// The server writes it despite never reading it because the per-enrollment
  /// namespace it lands in admits writes only from that enrollment, and at
  /// approval that connection has never existed. The approver needs the
  /// record immediately, so it is the only party that can put it there in
  /// time.
  Map<String, dynamic>? apsk;

  /// The **bare** `_apsk` value: a plain RSA public key string, carried on
  /// `enroll:request` as `EnrollParams.apskLegacy` and published verbatim
  /// rather than JSON-encoded, because an `_apsk` consumer base64-decodes the
  /// value as an RSA key and a JSON one fails its parse.
  ///
  /// Mutually exclusive with [apsk], on the wire and at rest: one record
  /// publishes one value, so a request carrying both is refused and an
  /// `enroll:update` setting either one clears the other.
  String? apskLegacy;

  /// The enrollment that APPROVED this one, or null when nothing did.
  ///
  /// This is the approval edge, and revocation cascades along it to any depth:
  /// an enrollment holding `__manage` that admits others and is then revoked
  /// as compromised must not leave what it admitted authenticating.
  /// [EnrollmentManager.descendantsOf] walks this edge and no other.
  ///
  /// Set from the connection on `enroll:approve`, never from the request, so
  /// an approver cannot name someone else as the admitting party. A retrofit
  /// COPIES its predecessor's value rather than naming the predecessor: the
  /// successor is the same principal re-keyed, so it stands where its
  /// predecessor stood. Null there would make a retrofit an escape hatch from
  /// the cascade.
  ///
  /// Null for an enrollment approved over a connection carrying no enrollment
  /// id, since there is nothing there to revoke later, and for any record on
  /// which no approver was ever recorded: the edge is forward-only and cannot
  /// be reconstructed.
  String? parentEnrollmentId;

  /// The enrollment this one REPLACED in a retrofit, its predecessor, or
  /// null for every other origin.
  ///
  /// ⛔ Revocation does NOT cascade along this edge. A retrofit REPLACES: the
  /// successor is the same principal re-keyed, so revoking a superseded
  /// credential must not take the one that superseded it, or an operator
  /// retiring an old key kills the device's current one.
  ///
  /// What it is for: the once-off rule, which refuses to retrofit a successor
  /// again without an approver; the retrofit cap, which arms on the
  /// successor's first authentication and needs to know what it replaced; and
  /// tooling, which finds a sibling set by it when their parent is null.
  String? retrofitPredecessorEnrollmentId;

  /// When this enrollment settled what it replaced: the predecessor's
  /// approval children moved onto this one, and the predecessor was put on the
  /// retrofit cap unless it holds full privilege. Null while that is still
  /// open.
  ///
  /// Not a record of "a cap was written". A root predecessor keeps its life
  /// and still stamps this, as does one already deleted, so that a later
  /// connection does not re-walk a lookup for something that is never coming
  /// back. A predecessor that is not approved does not stamp, because that is
  /// a judgement about state which can change.
  ///
  /// The cap is armed by the successor's FIRST PKAM authentication rather than
  /// when the server stores the record. Storing proves only that the server
  /// wrote it, while the successor's APKAM private half lives client-side, so
  /// a failed keyfile write leaves the successor existing here and nowhere
  /// else with a clock already running on the only credential that still
  /// works. An authentication proves the private half survived.
  ///
  /// A stamp rather than a flag because the cap RE-ARMS: each sibling
  /// replacing the same predecessor pushes the deadline out afresh, so the
  /// predecessor retires one grace period after the LAST of them
  /// authenticates. Only the first authentication of any one successor arms
  /// it, or every reconnect would extend the predecessor's life and it would
  /// never retire.
  DateTime? predecessorCapArmedAt;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  /// A "root" enrollment: read-write on every namespace AND on `__manage`.
  ///
  /// What the first (CRAM-path) enrollment is auto-granted, and what a later
  /// one must be given explicitly. Holding `*` alone does not qualify, and
  /// neither does `__manage` alone.
  ///
  /// Full privilege rather than the ability to approve, because the two differ
  /// and the difference decides whether an atSign can recover: approving is
  /// checked per namespace against what the approver itself holds, so an
  /// enrollment with `__manage` but not `*` can admit new enrollments yet
  /// never one carrying `*`. It keeps an atSign running but cannot restore a
  /// root to it.
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

  /// The roster view: everything an administrator needs to render this
  /// enrollment, audit it and decide what to ask of it, and none of the key
  /// material that would let one USE it.
  ///
  /// An explicit field set rather than [toJsonExtended] with the secrets
  /// blanked, so a new field on the record is absent from this view until
  /// somebody adds it deliberately. That is the direction that fails safe.
  ///
  /// Omitted: `encryptedAPKAMSymmetricKey` and `apsk`/`apskLegacy` (wrapped
  /// key material), `apkamPublicKey` and `metadata` (which carries the key
  /// package, and identifies the credential), and `sessionId`. None is needed
  /// to decide whether an enrollment should stand.
  Map<String, dynamic> toJsonRoster() => <String, dynamic>{
        'appName': appName,
        'deviceName': deviceName,
        'namespaces': namespaces,
        // The alias toJsonExtended emits, kept so a roster entry reads the
        // same either side of the redaction.
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
