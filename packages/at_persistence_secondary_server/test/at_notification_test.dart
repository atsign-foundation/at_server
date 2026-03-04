import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  group('Notification expirations', () {
    test('test notification expired via ttl', () async {
      final notificationBuilder = AtNotificationBuilder()..ttl = 1;
      final atNotification = notificationBuilder.build();
      sleep(Duration(milliseconds: 2));
      expect(atNotification.isExpired(), true);
    });

    test('test notification expired via status', () {
      var n = (AtNotificationBuilder()
            ..notificationStatus = NotificationStatus.expired)
          .build();
      expect(n.isExpired(), true);
      n = (AtNotificationBuilder()
            ..notificationStatus = NotificationStatus.queued)
          .build();
      expect(n.isExpired(), false);
    });

    test('test notification expired via expiresAt', () {
      var n = (AtNotificationBuilder()
            ..expiresAt = DateTime.now().add(Duration(milliseconds: 10)))
          .build();
      expect(n.isExpired(), false);
      n = (AtNotificationBuilder()..expiresAt = DateTime.now()).build();
      expect(n.isExpired(), true);
    });

    test('test notification expired via notificationDateTime', () {
      var n = AtNotificationBuilder().build();
      expect(n.notificationDateTime!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch, 2));
      expect(n.isExpired(), false);

      n = (AtNotificationBuilder()
            ..notificationDateTime = DateTime.now()
                .subtract(AtNotification.notificationDateTimeExpiryTimeout)
                .subtract(Duration(milliseconds: 1)))
          .build();
      expect(n.isExpired(), true);
    });

    test('test notification not expired via ttl', () async {
      final notificationBuilder = AtNotificationBuilder()..ttl = 5;
      final atNotification = notificationBuilder.build();
      expect(atNotification.isExpired(), false);
    });

    test('test notificationExpiry time', () {
      //when ttl is not passed, 15-mins is used as the default ttl
      final notification = AtNotificationBuilder().build();

      //notification.expiresAt and notifExpiresAt have the difference of a
      // couple of milli seconds and cannot asserted to be equal
      // the statement below asserts that the actual expiresAt time is within
      // a range of 2 milliseconds of the expected expiresAt
      var notifExpiresAt = DateTime.now().toUtc().add(Duration(minutes: 15));
      expect(notification.expiresAt!.millisecondsSinceEpoch,
          closeTo(notifExpiresAt.millisecondsSinceEpoch, 2));
    });

    test('test builder reset', () async {
      final b = AtNotificationBuilder();
      expect(
          b.ttl,
          Duration(minutes: AtNotificationBuilder.defaultTTLInMins)
              .inMilliseconds);
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch, 2));
      b.ttl = 333333;
      expect(b.ttl, 333333);

      final ndt1 = b.notificationDateTime;

      await Future.delayed(Duration(milliseconds: 10));
      b.reset();
      expect(
          b.ttl,
          Duration(minutes: AtNotificationBuilder.defaultTTLInMins)
              .inMilliseconds);
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch, 2));
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          isNot(closeTo(ndt1!.millisecondsSinceEpoch, 2)));
    });
  });
}
