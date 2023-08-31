import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:test/test.dart';

bool isSelfNotificationTypeInvoked = false;
bool isReceivedNotificationTypeInvoked = false;
bool isSentNotificationTypeInvoked = false;

void main() async {
  group('A group of notification callback tests', () {
    test('test invoke call back null notification', () async {
      try {
        final atNotificationCallback = AtNotificationCallback.getInstance();
        atNotificationCallback.registerNotificationCallback(
            NotificationType.received, _receivedNotificationCallback);
        final atNotification = null;
        await atNotificationCallback.invokeCallbacks(atNotification);
        expect(isReceivedNotificationTypeInvoked, false);
      } finally {
        isReceivedNotificationTypeInvoked = false;
      }
    });

    test('test invoke call back - no registered callbacks', () async {
      try {
        final atNotificationCallback = AtNotificationCallback.getInstance();
        final atNotification = null;
        await atNotificationCallback.invokeCallbacks(atNotification);
        expect(isReceivedNotificationTypeInvoked, false);
      } finally {
        isReceivedNotificationTypeInvoked = false;
      }
    });

    test('test self notification callback', () async {
      try {
        final atNotificationCallback = AtNotificationCallback.getInstance();
        atNotificationCallback.registerNotificationCallback(
            NotificationType.self, _selfNotificationCallback);
        final atNotification = (AtNotificationBuilder()
              ..type = NotificationType.self
              ..notification = 'test')
            .build();
        await atNotificationCallback.invokeCallbacks(atNotification);
        expect(isSelfNotificationTypeInvoked, true);
      } finally {
        isSelfNotificationTypeInvoked = false;
      }
    });

    test('test received notification callback', () async {
      try {
        final atNotificationCallback = AtNotificationCallback.getInstance();
        atNotificationCallback.registerNotificationCallback(
            NotificationType.received, _receivedNotificationCallback);
        final atNotification = (AtNotificationBuilder()
              ..type = NotificationType.received
              ..notification = 'test')
            .build();
        await atNotificationCallback.invokeCallbacks(atNotification);
        expect(isReceivedNotificationTypeInvoked, true);
      } finally {
        isReceivedNotificationTypeInvoked = false;
      }
    });

    test('test sent notification callback', () async {
      try {
        final atNotificationCallback = AtNotificationCallback.getInstance();
        atNotificationCallback.registerNotificationCallback(
            NotificationType.sent, _sentNotificationCallback);
        final atNotification = (AtNotificationBuilder()
              ..type = NotificationType.sent
              ..notification = 'test')
            .build();
        await atNotificationCallback.invokeCallbacks(atNotification);
        expect(isSentNotificationTypeInvoked, false);
      } finally {
        isSentNotificationTypeInvoked = false;
      }
    });
  });
}

void _selfNotificationCallback(AtNotification notification) {
  isSelfNotificationTypeInvoked = true;
}

void _receivedNotificationCallback(AtNotification notification) {
  isReceivedNotificationTypeInvoked = true;
}

void _sentNotificationCallback(AtNotification notification) {
  isSentNotificationTypeInvoked = true;
}
