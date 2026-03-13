import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  group('AtNotificationBuilder tests of ttl and expiresAt', () {
    test('expiresAt null, ttl 0', () {
      final b = AtNotificationBuilder()..ttl = 0;
      expect(b.ttl, 0);
      expect(b.expiresAt, null);

      b.build();
      expect(b.ttl, AtNotification.defaultTtl.inMilliseconds);
      expect(
          b.expiresAt!.millisecondsSinceEpoch,
          closeTo(
              DateTime.now().millisecondsSinceEpoch +
                  AtNotification.defaultTtl.inMilliseconds,
              5));
      final n = b.build();
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });

    test('expiresAt null, ttl negative', () {
      final b = AtNotificationBuilder()..ttl = -1000;
      expect(b.ttl, -1000);
      expect(b.expiresAt, null);

      b.build();
      expect(b.ttl, AtNotification.defaultTtl.inMilliseconds);
      expect(
          b.expiresAt!.millisecondsSinceEpoch,
          closeTo(
              DateTime.now().millisecondsSinceEpoch +
                  AtNotification.defaultTtl.inMilliseconds,
              5));
      final n = b.build();
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });
    test('expiresAt null, ttl null', () {
      final b = AtNotificationBuilder()..ttl = null;
      expect(b.ttl, null);
      expect(b.expiresAt, null);

      b.build();
      expect(
          b.expiresAt!.millisecondsSinceEpoch,
          closeTo(
              DateTime.now().millisecondsSinceEpoch +
                  AtNotification.defaultTtl.inMilliseconds,
              5));
      final n = b.build();
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });
    test('expiresAt null, ttl set to < max', () {
      int testTtl = (AtNotification.maxTtl.inMilliseconds / 2).floor();
      final b = AtNotificationBuilder()..ttl = testTtl;
      expect(b.expiresAt, null);
      b.build();
      expect(b.expiresAt!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch + testTtl, 5));
      final n = b.build();
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });
    test('expiresAt null, ttl set to == max', () {
      int testTtl = AtNotification.maxTtl.inMilliseconds;
      final b = AtNotificationBuilder()..ttl = testTtl;
      expect(b.expiresAt, null);
      b.build();
      expect(b.expiresAt!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch + testTtl, 5));
      final n = b.build();
      expect(b.ttl, AtNotification.maxTtl.inMilliseconds);
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });
    test('expiresAt null, ttl set to max plus 1ms', () {
      int testTtl = AtNotification.maxTtl.inMilliseconds + 1;
      final b = AtNotificationBuilder()..ttl = testTtl;
      expect(b.expiresAt, null);
      b.build();
      expect(
          b.expiresAt!.millisecondsSinceEpoch,
          closeTo(
              DateTime.now().millisecondsSinceEpoch +
                  AtNotification.maxTtl.inMilliseconds,
              5));
      final n = b.build();
      expect(b.ttl, AtNotification.maxTtl.inMilliseconds);
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
    });
    test('expiresAt null, ttl set to max plus 5 seconds', () {
      int testTtl = AtNotification.maxTtl.inMilliseconds + 5000;
      final b = AtNotificationBuilder()..ttl = testTtl;
      expect(b.expiresAt, null);
      b.build();
      expect(
          b.expiresAt!.millisecondsSinceEpoch,
          closeTo(
              DateTime.now().millisecondsSinceEpoch +
                  AtNotification.maxTtl.inMilliseconds,
              5));
      final n = b.build();
      expect(b.ttl, AtNotification.maxTtl.inMilliseconds);
      expect(n.ttl, b.ttl);
      expect(n.expiresAt, b.expiresAt);
      expect(n.isExpired(), false);
    });

    test('expiresAt in the past', () {
      final testVal = DateTime.now()
          .toUtcMillisecondsPrecision()
          .subtract(Duration(milliseconds: 1));
      final b = AtNotificationBuilder()
        ..ttl = null
        ..expiresAt = testVal;
      final n = b.build();
      expect(n.expiresAt, testVal);
      expect(n.isExpired(), true);
      // Even though ttl is not relevant here, we do want to make sure it is
      // non-null since this was expected behaviour up until now
      expect(n.ttl, AtNotification.defaultTtl.inMilliseconds);
    });
    test('expiresAt in the future < max', () {
      final testVal =
          DateTime.now().toUtcMillisecondsPrecision().add(Duration(minutes: 5));
      final b = AtNotificationBuilder()
        ..ttl = null
        ..expiresAt = testVal;
      final n = b.build();
      expect(n.expiresAt, testVal);
      expect(n.isExpired(), false);
      // Even though ttl is not relevant here, we do want to make sure it is
      // non-null since this was expected behaviour up until now
      expect(n.ttl, AtNotification.defaultTtl.inMilliseconds);
    });
    test('expiresAt in the future == max', () {
      final testVal = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(AtNotification.maxTtl);
      final b = AtNotificationBuilder()
        ..ttl = null
        ..expiresAt = testVal;
      final n = b.build();
      expect(n.expiresAt, testVal);
      expect(n.isExpired(), false);
      // Even though ttl is not relevant here, we do want to make sure it is
      // non-null since this was expected behaviour up until now
      expect(n.ttl, AtNotification.defaultTtl.inMilliseconds);
    });
    test('expiresAt in the future > max', () {
      final maxVal = DateTime.now()
          .toUtcMillisecondsPrecision()
          .add(AtNotification.maxTtl);
      final testVal = maxVal.add(Duration(minutes: 5));
      final b = AtNotificationBuilder()
        ..ttl = null
        ..expiresAt = testVal;
      final n = b.build();
      expect(n.expiresAt, isNot(testVal));
      expect(n.expiresAt!.millisecondsSinceEpoch,
          isNot(closeTo(testVal.millisecondsSinceEpoch, 5)));
      expect(n.expiresAt!.millisecondsSinceEpoch,
          closeTo(maxVal.millisecondsSinceEpoch, 5));
      expect(n.isExpired(), false);
      // Even though ttl is not relevant here, we do want to make sure it is
      // non-null since this was expected behaviour up until now
      expect(n.ttl, AtNotification.defaultTtl.inMilliseconds);
    });
  });
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
          closeTo(DateTime.now().millisecondsSinceEpoch, 5));
      expect(n.isExpired(), false);

      n = (AtNotificationBuilder()
            ..notificationDateTime = DateTime.now()
                .subtract(AtNotification.maxTtl)
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
          closeTo(notifExpiresAt.millisecondsSinceEpoch, 5));
    });

    test('test builder reset', () async {
      final b = AtNotificationBuilder();
      expect(b.ttl, AtNotification.defaultTtl.inMilliseconds);
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch, 5));
      b.ttl = 333333;
      expect(b.ttl, 333333);

      final ndt1 = b.notificationDateTime;

      await Future.delayed(Duration(milliseconds: 20));
      b.reset();
      expect(b.ttl, AtNotification.defaultTtl.inMilliseconds);
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          closeTo(DateTime.now().millisecondsSinceEpoch, 5));
      expect(b.notificationDateTime!.millisecondsSinceEpoch,
          isNot(closeTo(ndt1!.millisecondsSinceEpoch, 5)));
    });
  });
}
