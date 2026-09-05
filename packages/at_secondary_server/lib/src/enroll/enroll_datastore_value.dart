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
  Map<String, String> namespaces = {};
  late String apkamPublicKey;
  EnrollRequestType? requestType;
  EnrollApproval? approval;
  String? encryptedAPKAMSymmetricKey;
  Duration apkamKeysExpiryDuration = Duration(milliseconds: 0);

  /// Opaque per-APKAM metadata the client stores, returned verbatim in
  /// `enroll:listns` responses. By convention the enrollment's APKAM-signed
  /// key package lives under `metadata['keyPackage']`.
  Map<String, dynamic>? metadata;

  /// The signing algorithm of [apkamPublicKey]: `rsa2048` (the legacy
  /// default) or `mldsa65`.
  String? signingAlgo;

  /// The client-composed value published at
  /// `public:_apsk.<enrollmentId>.a.__e@<atSign>` when this enrollment is
  /// approved, carried on `enroll:request` as `EnrollParams.apsk`.
  ///
  /// Opaque to the server, exactly like [metadata]. Null means no `_apsk` is
  /// published for this enrollment at all.
  Map<String, dynamic>? apsk;

  /// The **bare** `_apsk` value: a plain RSA public key string, carried on
  /// `enroll:request` as `EnrollParams.apskLegacy` and published verbatim
  /// rather than JSON-encoded.
  ///
  /// Mutually exclusive with [apsk]: a request carrying both is refused, and
  /// an `enroll:update` setting either one clears the other.
  String? apskLegacy;

  /// The enrollment that APPROVED this one, or null when nothing did.
  ///
  /// Set from the connection on `enroll:approve`, never from the request; a
  /// retrofit copies its predecessor's value rather than naming it. Null for
  /// an enrollment approved over a connection carrying no enrollment id, and
  /// for any record on which no approver was ever recorded.
  String? parentEnrollmentId;

  /// The enrollment this one REPLACED in a retrofit, its predecessor, or
  /// null for every other origin.
  ///
  /// ⛔ Revocation does NOT cascade along this edge: a retrofit REPLACES, so
  /// revoking a superseded credential must not take the one that superseded
  /// it.
  String? retrofitPredecessorEnrollmentId;

  /// When this enrollment settled what it replaced, at its first PKAM
  /// authentication; null while that is still open.
  DateTime? predecessorSettledAt;

  /// The at-rest shape of this record: 1 for every record this build writes,
  /// 0 for one written before the field existed.
  int recordVersion = 1;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  /// A "root" enrollment: read-write on every namespace AND on `__manage`.
  ///
  /// Holding `*` alone does not qualify, and neither does `__manage` alone.
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
  /// somebody adds it deliberately.
  Map<String, dynamic> toJsonRoster() => <String, dynamic>{
        'recordVersion': recordVersion,
        'appName': appName,
        'deviceName': deviceName,
        'namespaces': namespaces,
        // The alias toJsonExtended emits.
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
        if (predecessorSettledAt != null)
          'predecessorSettledAt': predecessorSettledAt!.toIso8601String(),
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
