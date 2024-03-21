import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'test_utils.dart';

void main() {
  late MockSocket mockSocket;

  setUpAll(() async {
    await verbTestsSetUpAll();
    mockSocket = MockSocket();
    when(() => mockSocket.setOption(SocketOption.tcpNoDelay, true))
        .thenReturn(true);
  });
  group('A group of abstract verb handler tests', () {
    late String enrollmentId;
    setUp(() async {
      await verbTestsSetUp();

      inboundConnection.metadata.isAuthenticated =
          true; // owner connection, authenticated
      enrollmentId = Uuid().v4();
      inboundConnection.metadata.enrollmentId = enrollmentId;
      final enrollJson = {
        'sessionId': '123',
        'appName': 'wavi',
        'deviceName': 'pixel',
        'namespaces': {'wavi': 'rw'},
        'apkamPublicKey': 'testPublicKeyValue',
        'requestType': 'newEnrollment',
        'approval': {'state': 'approved'}
      };
      var keyName = '$enrollmentId.new.enrollments.__manage@alice';
      await secondaryKeyStore.put(
          keyName, AtData()..data = jsonEncode(enrollJson));
    });
    test(
        'test isAuthorized command with namespace in atKey and namespace  passed with identical value',
        () async {
      var handler = TestUpdateVerbHandler(secondaryKeyStore);
      var atKey = AtKey()
        ..sharedBy = '@alice'
        ..sharedWith = '@bob'
        ..namespace = 'wavi'
        ..key = 'phone';
      var isAuthorized = await handler.isAuthorized(
          inboundConnection.metaData as InboundConnectionMetadata,
          atKey: atKey.toString(),
          namespace: 'wavi');
      expect(isAuthorized, true);
    });
    test(
        'test isAuthorized command with namespace in atKey and namespace passed with different values',
        () async {
      var handler = TestUpdateVerbHandler(secondaryKeyStore);
      var atKey = AtKey()
        ..sharedBy = '@alice'
        ..sharedWith = '@bob'
        ..namespace = 'wavi'
        ..key = 'phone';
      expect(
          () async => await handler.isAuthorized(
              inboundConnection.metaData as InboundConnectionMetadata,
              atKey: atKey.toString(),
              namespace: 'buzz'),
          throwsA(predicate((dynamic e) =>
              e is AtEnrollmentException &&
              e.message ==
                  'AtKey namespace and passed namespace do not match')));
    });
  });
}

class TestUpdateVerbHandler extends AbstractVerbHandler {
  TestUpdateVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) {
    // TODO: implement accept
    throw UnimplementedError();
  }

  @override
  Verb getVerb() {
    return Update();
  }

  @override
  Future<bool> isOTPValid(String? otp) {
    // TODO: implement isOTPValid
    throw UnimplementedError();
  }

  @override
  HashMap<String, String?> parse(String command) {
    // TODO: implement parse
    throw UnimplementedError();
  }

  @override
  Future<void> process(String command, InboundConnection atConnection) {
    // TODO: implement process
    throw UnimplementedError();
  }

  @override
  Future<Response> processInternal(
      String command, InboundConnection atConnection) {
    // TODO: implement processInternal
    throw UnimplementedError();
  }

  @override
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection) {
    // TODO: implement processVerb
    throw UnimplementedError();
  }
}
