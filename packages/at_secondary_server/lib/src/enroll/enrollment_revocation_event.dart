/// What happened to an enrollment's revocation state.
enum EnrollmentRevocationEventType {
  /// The enrollment became revoked, by name or by cascade.
  revoked,

  /// A revocation was withdrawn: the enrollment went back to approved.
  unrevoked,
}

/// One moment an enrollment's revocation state changed.
class EnrollmentRevocationEvent {
  final EnrollmentRevocationEventType type;

  /// The enrollment whose state changed.
  final String enrollmentId;

  /// When, by the atServer's own clock; one command's events share a moment.
  final DateTime at;

  /// The namespace grants [enrollmentId] held at that moment.
  final Map<String, String> namespaces;

  /// The enrollment on the connection that issued the command, or null when
  /// the connection carried no enrollment id, a CRAM connection.
  final String? byEnrollmentId;

  /// The enrollment the command NAMED when this event is a consequence of
  /// revoking that one; null when [enrollmentId] is what the operator named.
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
  /// including an event kind it does not know.
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

  /// ⚠️ AT-REST PIN: these names are frozen and pinned as raw literals in
  /// enroll_revocation_event_test.dart.
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
