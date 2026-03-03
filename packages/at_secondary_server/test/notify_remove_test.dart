import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_remove_verb_handler.dart';
import 'package:at_server_spec/verbs.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  group('A group of test to verify NotifyDeleteVerb', () {
    test('Test to verify notify delete getVerb', () {
      var handler =
          NotifyRemoveVerbHandler(secondaryKeyStore, notificationManager);
      var verb = handler.getVerb();
      expect(verb is NotifyRemove, true);
    });
  });

  group('A group of hive tests to verify notify delete', () {
    test('A test to verify notify remove', () async {
      // Notification Object
      var notificationObj = (AtNotificationBuilder()
            ..id = '122'
            ..fromAtSign = '@test_user_1'
            ..notificationDateTime = DateTime.now().subtract(Duration(days: 1))
            ..toAtSign = '@test_user_1'
            ..notification = 'key1'
            ..type = NotificationType.received)
          .build();
      await notifStore.put('122', notificationObj);

      // Dummy Inbound connection
      var atConnection = InboundConnectionImpl(FakeSocket(), '123')
        ..metaData = (InboundConnectionMetadata()
          ..fromAtSign = alice
          ..isAuthenticated = true);
      var response = Response();
      // Verify Notification is inserted into keystore
      var notifyListVerbHandler =
          NotifyListVerbHandler(secondaryKeyStore, notificationManager);
      var notifyListParams = getVerbParam(NotifyList().syntax(), 'notify:list');
      await notifyListVerbHandler.processVerb(
          response, notifyListParams, atConnection);

      //Notify delete verb handler
      var notifyDeleteHandler = NotifyRemoveVerbHandler(
        secondaryKeyStore,
        notificationManager,
      );

      await notifyDeleteHandler.processVerb(
          response,
          getVerbParam(NotifyRemove().syntax(), 'notify:remove:122'),
          atConnection);
      expect(response.data, 'success');

      // Notify List to verify after deletion
      await notifyListVerbHandler.processVerb(
          response, notifyListParams, atConnection);
      expect(response.data, null);
    });
  });
}
