import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

void main() async {
  group('A group notification model test', () {
    test('test notification expired', () async {
      final notificationBuilder = AtNotificationBuilder()..ttl = 100;
      final atNotification = notificationBuilder.build();
      sleep(Duration(milliseconds: 200));
      expect(atNotification.isExpired(), true);
    });

    test('test notification not expired', () async {
      final notificationBuilder = AtNotificationBuilder()..ttl = 500;
      final atNotification = notificationBuilder.build();
      sleep(Duration(milliseconds: 50));
      expect(atNotification.isExpired(), false);
    });

    test('test notificationExpiry time', () {
      final builder = AtNotificationBuilder();
      final notification = builder.build();
      var notifExpiresAt = DateTime.now().toUtc().add(Duration(minutes: 15));
      //when ttl is not passed, 15-mins is used as the default ttl
      //notification.expiresAt and notifExpiresAt have the difference of a
      // couple of milli seconds and they cannot asserted to be equal
      expect(notification.expiresAt?.year, notifExpiresAt.year);
      expect(notification.expiresAt?.month, notifExpiresAt.month);
      expect(notification.expiresAt?.day, notifExpiresAt.day);
      expect(notification.expiresAt?.hour, notifExpiresAt.hour);
      expect(notification.expiresAt?.minute, notifExpiresAt.minute);
      expect(notification.expiresAt?.second, notifExpiresAt.second);
    });
  });
}
