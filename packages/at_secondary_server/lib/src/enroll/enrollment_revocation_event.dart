/// What happened to an enrollment's revocation state.
enum EnrollmentRevocationEventType {
  /// The enrollment became revoked — because an operator named it, or because
  /// a cascade swept it up with the enrollment it replaced.
  revoked,

  /// A revocation was withdrawn: the enrollment went back to approved.
  unrevoked,
}

/// One moment an enrollment's revocation state changed.
///
/// Recorded as a record of its OWN, rather than as a field on the enrollment,
/// so the fact outlives the enrollment it describes. An enrollment record
/// carries the APKAM key-expiry posture as its ttl, so a revoked enrollment
/// is reaped on the schedule its credential was issued under — and a stamp
/// living on that record disappears with it. The answer to "when was anything
/// holding this namespace last revoked" would then go BACKWARDS, which reads
/// to a client exactly like "nothing has changed since you last asked".
///
/// It also records what the field could not. A revoked enrollment's grants are
/// the only evidence of which namespaces a revocation touched, and they leave
/// with the record; an event keeps them. And an un-revoke used to CLEAR the
/// stamp, so a revocation that was withdrawn left nothing behind at all —
/// which is the case an audit most wants to see.
class EnrollmentRevocationEvent {
  final EnrollmentRevocationEventType type;

  /// The enrollment whose state changed.
  final String enrollmentId;

  /// When, by the atServer's own clock.
  ///
  /// Every event of one operation shares one moment, including a cascade's:
  /// the enrollments a cascade takes are revoked by a single act, and stamping
  /// each with the instant its own write happened would invite a reader to
  /// order them against one another as though they were separate decisions.
  final DateTime at;

  /// The namespace grants [enrollmentId] held at that moment.
  ///
  /// Copied rather than looked up later, because the enrollment record is
  /// exactly what may be gone by the time anyone reads this.
  final Map<String, String> namespaces;

  /// The enrollment on the connection that issued the command, or null when
  /// the connection carried no enrollment id — a CRAM or legacy-PKAM owner.
  final String? byEnrollmentId;

  /// The enrollment the command NAMED, when this event is a consequence of
  /// revoking that one rather than of naming this one. Null when
  /// [enrollmentId] is what the operator asked for.
  ///
  /// Separate from [byEnrollmentId] because they answer different questions —
  /// who did this, and why this enrollment — and a cascade is precisely the
  /// case where the two differ.
  final String? cascadedFrom;

  EnrollmentRevocationEvent({
    required this.type,
    required this.enrollmentId,
    required this.at,
    required this.namespaces,
    required this.byEnrollmentId,
    required this.cascadedFrom,
  });

  /// Throws [FormatException] on anything it cannot read as an event,
  /// including an event kind it does not know. A reader skips those rather
  /// than guessing: a future kind that neither revokes nor un-revokes would be
  /// miscounted by any default, and miscounting here moves a security answer.
  factory EnrollmentRevocationEvent.fromJson(Map<String, dynamic> json) {
    final Object? kind = json['event'];
    final EnrollmentRevocationEventType type;
    if (kind == EnrollmentRevocationEventType.revoked.name) {
      type = EnrollmentRevocationEventType.revoked;
    } else if (kind == EnrollmentRevocationEventType.unrevoked.name) {
      type = EnrollmentRevocationEventType.unrevoked;
    } else {
      throw FormatException('unknown revocation event kind: $kind');
    }
    final Object? enrollmentId = json['enrollmentId'];
    if (enrollmentId is! String) {
      throw FormatException('revocation event has no enrollmentId: $json');
    }
    final Object? at = json['at'];
    if (at is! String) {
      throw FormatException('revocation event has no timestamp: $json');
    }
    return EnrollmentRevocationEvent(
      type: type,
      enrollmentId: enrollmentId,
      at: DateTime.parse(at),
      namespaces: (json['namespaces'] as Map?)?.map(
              (key, value) => MapEntry(key as String, value as String)) ??
          <String, String>{},
      byEnrollmentId: json['byEnrollmentId'] as String?,
      cascadedFrom: json['cascadedFrom'] as String?,
    );
  }

  /// The at-rest shape. The names here are a stored format, not an
  /// implementation detail: records written by one release are read by the
  /// next, so enroll_revocation_event_test.dart pins every one of them as a
  /// raw literal.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'event': type.name,
        'enrollmentId': enrollmentId,
        'at': at.toIso8601String(),
        'namespaces': namespaces,
        if (byEnrollmentId != null) 'byEnrollmentId': byEnrollmentId,
        if (cascadedFrom != null) 'cascadedFrom': cascadedFrom,
      };

  @override
  String toString() => 'EnrollmentRevocationEvent(${type.name} $enrollmentId '
      'at $at by $byEnrollmentId cascadedFrom $cascadedFrom)';
}
