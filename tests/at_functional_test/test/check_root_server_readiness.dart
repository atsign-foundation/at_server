import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

var maxRetryCount = 100;
var retryCount = 1;
Queue rootServerResponseQueue = Queue();

void main() {
  var atsign = 'sitaram🛠';
  var rootServerPort = 64;
  var rootServer = 'vip.ve.atsign.zone';

  late SecureSocket _secureSocket;

  test('checking for test environment readiness', () async {
    while (retryCount < maxRetryCount) {
      try {
        _secureSocket = await SecureSocket.connect(rootServer, rootServerPort,
            timeout: Duration(seconds: 1));
        socketListener(_secureSocket);
        while (rootServerResponseQueue.isEmpty) {
          _secureSocket.write('$atsign\n');
          await Future.delayed(Duration(milliseconds: 10));
          if (rootServerResponseQueue.isNotEmpty) {
            var rootResponse = rootServerResponseQueue.removeFirst();
            print('Root server started: $rootResponse');
            await _secureSocket.close();
            break;
          } else {
            print(
                'Waiting for the root server to start: RetryCount: $retryCount');
          }
        }
      } on SocketException {
        print('Waiting for the root server to start: RetryCount: $retryCount');
        await Future.delayed(Duration(seconds: 5));
        retryCount = retryCount + 1;
      } on HandshakeException {
        print('Waiting for the root server to start: RetryCount: $retryCount');
        await Future.delayed(Duration(seconds: 5));
        retryCount = retryCount + 1;
      }
    }

  }, timeout: Timeout(Duration(minutes: 1)));
}

void socketListener(SecureSocket secureSocket) {
  var response = '';
  secureSocket.listen((event) {
    response = utf8.decode(event);
    if (response.isNotEmpty) {
      rootServerResponseQueue.add(response);
    }
  });
}
