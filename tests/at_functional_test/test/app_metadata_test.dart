// Functional round-trip tests for Metadata.appMetadata: the
// base64(JSON) `:appMetadata:` fragment on update / update:meta /
// notify, verified back out through llookup:all, llookup:meta and
// notify:fetch against a running atServer.

import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  final appMetadataJson = {
    'providerId': 'acme_provider',
    'keyId': 'k-123',
    'mode': 'hpke',
  };
  final encodedAppMetadata =
      base64Encode(utf8.encode(jsonEncode(appMetadataJson)));

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });

  void expectAppMetadata(dynamic appMetadataValue) {
    expect(appMetadataValue, isNotNull,
        reason: 'appMetadata absent from metaData');
    expect(appMetadataValue['providerId'], 'acme_provider');
    expect(appMetadataValue['keyId'], 'k-123');
    expect(appMetadataValue['mode'], 'hpke');
  }

  group('A group of tests verifying appMetadata round-tripping', () {
    test('update with appMetadata; llookup:all returns it', () async {
      String key = 'appmeta-$uniqueId$firstAtSign';
      var response = await firstAtSignConnection.sendRequestToServer(
          'update:appMetadata:$encodedAppMetadata:$key some-value');
      expect(response, contains(RegExp(r'data:\d+')));

      response =
          (await firstAtSignConnection.sendRequestToServer('llookup:all:$key'))
              .replaceFirst('data:', '');
      var atData = jsonDecode(response);
      expect(atData['data'], 'some-value');
      expectAppMetadata(atData['metaData']['appMetadata']);
    });

    test('a subsequent update without appMetadata retains it', () async {
      String key = 'appmeta-retain-$uniqueId$firstAtSign';
      await firstAtSignConnection.sendRequestToServer(
          'update:appMetadata:$encodedAppMetadata:$key first-value');
      var response = await firstAtSignConnection
          .sendRequestToServer('update:$key second-value');
      expect(response, contains(RegExp(r'data:\d+')));

      response =
          (await firstAtSignConnection.sendRequestToServer('llookup:all:$key'))
              .replaceFirst('data:', '');
      var atData = jsonDecode(response);
      expect(atData['data'], 'second-value');
      expectAppMetadata(atData['metaData']['appMetadata']);
    });

    test('update:meta sets appMetadata on an existing key; value intact',
        () async {
      String key = 'appmeta-meta-$uniqueId$firstAtSign';
      await firstAtSignConnection
          .sendRequestToServer('update:$key meta-test-value');
      var response = await firstAtSignConnection.sendRequestToServer(
          'update:meta:$key:appMetadata:$encodedAppMetadata');
      expect(response, contains(RegExp(r'data:\d+')));

      // llookup:meta surfaces it
      response =
          (await firstAtSignConnection.sendRequestToServer('llookup:meta:$key'))
              .replaceFirst('data:', '');
      expectAppMetadata(jsonDecode(response)['appMetadata']);

      // and the value is untouched
      response =
          await firstAtSignConnection.sendRequestToServer('llookup:$key');
      expect(response, 'data:meta-test-value');
    });

    test('notify with appMetadata; notify:fetch shows it stored', () async {
      String key = 'appmeta-notify-$uniqueId.me$firstAtSign';
      var notificationId = await firstAtSignConnection.sendRequestToServer(
          'notify:appMetadata:$encodedAppMetadata:$firstAtSign:$key');
      notificationId = notificationId.replaceFirst('data:', '').trim();

      var response = (await firstAtSignConnection
              .sendRequestToServer('notify:fetch:$notificationId'))
          .replaceFirst('data:', '');
      var atNotificationMap = jsonDecode(response);
      expect(atNotificationMap['id'], notificationId);
      // notify:fetch stringifies the atMetadata map (pre-existing
      // response shape), so assert on the provider fields textually.
      String atMetadataString = atNotificationMap['atMetadata'];
      expect(atMetadataString, contains('acme_provider'));
      expect(atMetadataString, contains('k-123'));
      expect(atMetadataString, contains('hpke'));
    });

    test('update with malformed appMetadata is rejected', () async {
      String key = 'appmeta-bad-$uniqueId$firstAtSign';
      var response = await firstAtSignConnection.sendRequestToServer(
          'update:appMetadata:%%%not-base64%%%:$key some-value');
      expect(response, contains('error'));
    });
  });
}
