import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

var maxRetryCount = 50;
var retryCount = 1;
Queue rootServerResponseQueue = Queue();

void main() {
  var rootServerPort = 64;
  var rootServer = 'vip.ve.atsign.zone';

  late SecureSocket _secureSocket;

  test('checking for root server readiness', () async {
    while (retryCount < maxRetryCount) {
      try {
        _secureSocket = await SecureSocket.connect(rootServer, rootServerPort,
            timeout: Duration(seconds: 1));
        socketListener(_secureSocket);
        var response = await readResponse();
        if (response == '@') {
          print('Root Server is up and running');
          await _secureSocket.close();
          break;
        }
      } on SocketException {
        print('Waiting for the root server to start: RetryCount: $retryCount');
        await Future.delayed(Duration(seconds: 2));
        retryCount = retryCount + 1;
      } on HandshakeException {
        print('Waiting for the root server to start: RetryCount: $retryCount');
        await Future.delayed(Duration(seconds: 2));
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

dynamic readResponse() async {
  while (rootServerResponseQueue.isEmpty) {
    await Future.delayed(Duration(milliseconds: 10));
  }
  return rootServerResponseQueue.removeFirst();
}
