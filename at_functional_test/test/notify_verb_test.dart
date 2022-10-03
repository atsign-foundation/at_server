import 'dart:convert';
import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'commons.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];

  Socket? socketFirstAtsign;

  //Establish the client socket connection
  setUp(() async {
    var firstAtsignServer =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    firstAtsignServer = firstAtsignServer.toString().trim();
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    // socket connection for first atsign
    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  group('A group of tests to verify notify fetch', () {
    test('A test to verify notification shared to current atSign is fetched',
        () async {
      // Store notification
      await socket_writer(
          socketFirstAtsign!, 'notify:$firstAtsign:phone.me$firstAtsign');
      var notificationId = await read();
      notificationId = notificationId.replaceFirst('data:', '');
      // Fetch notification using notification id
      await socket_writer(socketFirstAtsign!, 'notify:fetch:$notificationId');
      var response = await read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      expect(atNotificationMap['fromAtSign'], firstAtsign);
      expect(atNotificationMap['toAtSign'], firstAtsign);
      expect(atNotificationMap['type'], 'NotificationType.received');
    });

    test('A test to verify fetching notification that is deleted', () async {
      var notificationId = '124-abc';
      // Fetch notification using notification id that does not exist
      await socket_writer(socketFirstAtsign!, 'notify:fetch:$notificationId');
      var response = await read();
      response = response.replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId.trim());
      expect(atNotificationMap['notificationStatus'],
          'NotificationStatus.expired');
    });
  });
}
