import 'dart:async';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/from_verb_handler.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await verbTestsSetUp());
  tearDown(() async => await verbTestsTearDown());

  group('Given client certificates are required', () {
    test(
        'when another atSign sends from: on a connection that presents no '
        'client certificate, then it is refused', () async {
      expect(AtSecondaryConfig.clientCertificateRequired, isTrue);
      AtSecondaryServerImpl.getInstance()
        ..currentAtSign = alice
        ..secondaryAddressFinder = mockSecondaryAddressFinder;
      when(() => mockSecureSocket.peerCertificate).thenReturn(null);
      when(() => mockSecureSocket.remoteAddress)
          .thenReturn(InternetAddress.loopbackIPv4);
      when(() => mockSecureSocket.remotePort).thenReturn(1);
      registerFallbackValue(SocketOption.tcpNoDelay);
      when(() => mockSecureSocket.setOption(any(), any())).thenReturn(true);
      when(() => mockSecureSocket.done)
          .thenAnswer((_) => Completer<dynamic>().future);
      final InboundConnectionImpl connection =
          InboundConnectionImpl(mockSecureSocket, 'client-certificate-test');

      await expectLater(
          FromVerbHandler(keyValueStore,
                  commitLog: atCommitLog, accessLog: atAccessLog)
              .process('from:$bob', connection),
          throwsA(isA<UnAuthenticatedException>().having((e) => e.message,
              'message', contains('Certificate Verification Failed'))));
    });
  });
}
