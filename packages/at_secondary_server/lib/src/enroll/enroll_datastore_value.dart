import 'package:json_annotation/json_annotation.dart';

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

  /// The enrollment whose authenticated connection self-spawned this one
  /// (RF-SRV), or null for every other origin.
  ///
  /// Recorded so revocation can CASCADE: self-enrollment makes enrollments a
  /// parent/child graph, and a stolen keyfile can spawn a child before the
  /// theft is noticed — a child that survives its parent's revocation would
  /// defeat revocation via the very feature that created it
  /// (at_client_sdk docs/projects/pq/decisions.md 40). The cascade itself is
  /// the revoke path's to implement; this field is what makes it possible on
  /// records that already exist by then.
  String? parentEnrollmentId;

  EnrollDataStoreValue(
      this.sessionId, this.appName, this.deviceName, this.apkamPublicKey);

  factory EnrollDataStoreValue.fromJson(Map<String, dynamic> json) =>
      _$EnrollDataStoreValueFromJson(json);

  Map<String, dynamic> toJson() => _$EnrollDataStoreValueToJson(this);

  Map<String, dynamic> toJsonExtended() {
    final m = toJson();
    m['status'] = approval?.state;
    m['namespace'] = m['namespaces'];
    return m;
  }
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
