// The at-rest forms of a notification's quarantine mark and of the refused
// status, on both backends. These are frozen formats: an older atServer reads
// them, so each is pinned as a raw literal.

// ignore_for_file: implementation_imports
import 'dart:convert';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:at_persistence_secondary_server/src/impl/sqlite/sqlite_notification_codec.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/hive_impl.dart';
import 'package:test/test.dart';

void main() {
  AtNotification notification({required bool quarantined}) =>
      (AtNotificationBuilder()
            ..id = 'n1'
            ..fromAtSign = '@chuck'
            ..toAtSign = '@alice'
            ..notification = '@alice:inv1.invitations.chat@chuck'
            ..messageType = null
            ..priority = null
            ..notificationStatus = null
            ..notificationDateTime = DateTime.utc(2026, 10, 11, 9, 30)
            ..expiresAt = DateTime.utc(2026, 10, 11, 9, 45)
            ..quarantined = quarantined)
          .build();

  /// The fields of a Hive record, read the way every version of the adapter
  /// reads them: a count, then that many numbered fields.
  Map<int, dynamic> hiveFields(AtNotification n) {
    final writer = BinaryWriterImpl(HiveImpl());
    AtNotificationAdapter().write(writer, n);
    final reader = BinaryReaderImpl(writer.toBytes(), HiveImpl());
    final count = reader.readByte();
    return {for (int i = 0; i < count; i++) reader.readByte(): reader.read()};
  }

  group('Given the Hive notification adapter', () {
    test(
        'when a marked notification is written, then field 18 holds true and'
        ' it reads back marked', () {
      final Map<int, dynamic> fields =
          hiveFields(notification(quarantined: true));
      expect(fields.length, 19);
      expect(fields[18], true);
      final writer = BinaryWriterImpl(HiveImpl());
      AtNotificationAdapter().write(writer, notification(quarantined: true));
      expect(
          AtNotificationAdapter()
              .read(BinaryReaderImpl(writer.toBytes(), HiveImpl()))
              .quarantined,
          isTrue);
    });

    test(
        'when an unmarked notification is written, then it has the 18 fields'
        ' it always had', () {
      final Map<int, dynamic> fields =
          hiveFields(notification(quarantined: false));
      expect(fields.keys.toSet(), {for (int i = 0; i < 18; i++) i});
    });

    test(
        'when a marked record is read field by field, as an older adapter'
        ' reads it, then every older field is as written', () {
      final Map<int, dynamic> marked =
          hiveFields(notification(quarantined: true));
      final Map<int, dynamic> unmarked =
          hiveFields(notification(quarantined: false));
      expect({for (int i = 0; i < 18; i++) i: marked[i]}, unmarked);
    });

    test('when each status is written, then its byte is the one pinned for it',
        () {
      // NOTE byte 4 is refused; bytes 0 to 3 are as released.
      for (final (NotificationStatus status, int byte) in [
        (NotificationStatus.delivered, 0),
        (NotificationStatus.errored, 1),
        (NotificationStatus.queued, 2),
        (NotificationStatus.expired, 3),
        (NotificationStatus.refused, 4),
      ]) {
        final writer = BinaryWriterImpl(HiveImpl());
        NotificationStatusAdapter().write(writer, status);
        expect(writer.toBytes(), [byte], reason: status.name);
        expect(
            NotificationStatusAdapter()
                .read(BinaryReaderImpl(writer.toBytes(), HiveImpl())),
            status);
      }
    });
  });

  group('Given the SQLite notification codec', () {
    test(
        'when a marked notification is encoded, then its payload carries'
        ' "quarantined": true and it decodes marked', () {
      final String payload =
          SqliteNotificationCodec.encode(notification(quarantined: true));
      expect((jsonDecode(payload) as Map)['quarantined'], true);
      expect(SqliteNotificationCodec.decode(payload).quarantined, isTrue);
    });

    test(
        'when an unmarked notification is encoded, then its payload has no'
        ' quarantined key', () {
      final String payload =
          SqliteNotificationCodec.encode(notification(quarantined: false));
      expect((jsonDecode(payload) as Map).containsKey('quarantined'), isFalse);
      expect(SqliteNotificationCodec.decode(payload).quarantined, isFalse);
    });

    test('when a refused notification is encoded, then its status is "refused"',
        () {
      final AtNotification n = notification(quarantined: false)
        ..notificationStatus = NotificationStatus.refused;
      expect(SqliteNotificationCodec.statusExtract(n), 'refused');
      final String payload = SqliteNotificationCodec.encode(n);
      expect((jsonDecode(payload) as Map)['notificationStatus'], 'refused');
      expect(SqliteNotificationCodec.decode(payload).notificationStatus,
          NotificationStatus.refused);
    });
  });

  group('Given a notification for a client', () {
    test('when it is marked, then its JSON carries "quarantined": true', () {
      expect(notification(quarantined: true).toJson()['quarantined'], true);
    });

    test('when it is not marked, then its JSON has no quarantined key', () {
      expect(notification(quarantined: false).toJson().containsKey('quarantined'),
          isFalse);
    });
  });
}
