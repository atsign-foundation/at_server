import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/connection_util.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_message_listener.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() async {
  late FakeSocket socket;
  late InboundConnection connection;

  late AtConnectionMetaData authenticatedMetadata;
  late AtConnectionMetaData unAuthenticatedMetadata;

  setUpAll(() {
    verbTestsSetUpLogging();
    authenticatedMetadata = InboundConnectionMetadata()..isAuthenticated = true;
    unAuthenticatedMetadata = InboundConnectionMetadata();
  });

  setUp(() async {
    socket = FakeSocket();
    connection = MockInboundConnection();
    when(() => connection.close()).thenAnswer((_) async {});
    when(() => connection.isInValid()).thenReturn(false);

    final mockManager = MockInboundConnectionManager();
    final mockPool = MockInboundConnectionPool();
    when(() => mockManager.pool).thenReturn(mockPool);
    when(() => mockPool.remove(connection)).thenReturn(null);
    AtSecondaryServerImpl.getInstance().inboundConnectionManager = mockManager;
  });

  // testing InboundConnectionValidator.validate(), mainly focusing on what it throws and when
  // happy path of this group is covered by inbound message listener.
  group('A test to verify commands are properly invalidated in the buffer', () {
    test('validate a successful command -> should pass', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('lookup:public:publickey@alice\n').toList(),
            connection),
        returnsNormally,
      );
    });

    test('validate a failed verb (length > 32)', () {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('lookupdjflsdfspublickeylice:').toList(), connection),
        throwsA(isA<InvalidSyntaxException>()),
      );
    });

    test('validate a failed verb (trying to run authenticated verb)', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('monitor\n').toList(), connection),
        throwsA(isA<BlockedConnectionException>()),
      );
    });

    test('invalidate bad connection', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      when(() => connection.isInValid()).thenReturn(true);
      expect(
        () => InboundCommandValidator.validate(
            utf8.encode('monitor\n').toList(), connection),
        throwsA(isA<ConnectionInvalidException>()),
      );
    });

    test('invalidate (non authenticated junk)', () {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      when(() => connection.isInValid()).thenReturn(true);
      expect(
        () => InboundCommandValidator.validate(
            utf8
                .encode(
                    'monitoradshfajdsfkjalsdkjflaksdjlfkajsdlkfjalksdjflaksdjflaksdjflkadsjflkasdjflkajsdlkfjasldkfjalksdjflaksdjflaksdjfalskdfjalsdkfjalksdjfalksdjflaksdjflaksdjflaksdjflakdsjflakdsjfalksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjflaksdjfalskdjfalskdjfalksdjfalskdjfalksdjflaskdjfalksdjfalskdjfalsdkfjalsdkjf')
                .toList(),
            connection),
        throwsA(isA<ConnectionInvalidException>()),
      );
    });
  });

  group(
      'A test to verify that the message listener is properly handling commands in the buffer',
      () {
    test('validate one-word commands -> should pass', () async {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      var listener = InboundMessageListener(connection);
      final streamFuture = expectLater(
          socket.stream,
          emitsInOrder([
            equalsIgnoringCase('scan\n'),
            equalsIgnoringCase('info\n'),
          ]));
      listener.listen(callback, streamCallBack);
      socket.add(utf8.encode('scan\n').toList());
      socket.add(utf8.encode('info\n').toList());

      await streamFuture;
    });

    test('validate a colon separated command -> should pass', () async {
      when(() => connection.metaData).thenReturn(unAuthenticatedMetadata);
      var listener = InboundMessageListener(connection);
      var lookup = 'lookup:public:publickey@alice:metadata:ttl:0\n';
      var from = 'from:@mchicken\n';
      var pkam = 'pkam:superadvancedcoolsignature\n';
      final streamFuture = expectLater(
          socket.stream,
          emitsInOrder([
            equalsIgnoringCase(lookup),
            equalsIgnoringCase(from),
            equalsIgnoringCase(pkam),
          ]));
      listener.listen(callback, streamCallBack);
      socket.add(utf8.encode(lookup).toList());
      socket.add(utf8.encode(from).toList());
      socket.add(utf8.encode(pkam).toList());

      await streamFuture;
    });

    test('validate a colon & json included command -> should pass', () async {
      when(() => connection.metaData).thenReturn(authenticatedMetadata);
      var listener = InboundMessageListener(connection);
      listener.listen(callback, streamCallBack);
      var enroll =
          'enroll:request:{"appName":"wavi","deviceName":"iphone","namespaces":{"wavi":"rw"},"otp":"<otp>","apkamPublicKey":"<apkamPublicKey>","encryptedAPKAMSymmetricKey": "<encryptedAPKAMSymmetricKey>"}';
      final streamFuture = expectLater(
          socket.stream,
          emitsInOrder([
            equalsIgnoringCase(enroll),
          ]));
      socket.add(utf8.encode(enroll).toList());
      await streamFuture;
    });
  });
}

void callback(String value, InboundConnection connection) {}

void streamCallBack(List<int> data, InboundConnection connection) {}
