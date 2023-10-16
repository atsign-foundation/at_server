import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

var maxRetryCount = 50;
var retryCount = 1;
Queue rootServerResponseQueue = Queue();

void main() {
  var atSign = 'sitaram🛠';
  var rootServerPort = 64;
  var rootServer = 'vip.ve.atsign.zone';

  late SecureSocket _secureSocket;

  bool isRootServerStarted = false;

  test('checking for root server readiness', () async {
    while (retryCount < maxRetryCount) {
      try {
        _secureSocket = await SecureSocket.connect(rootServer, rootServerPort,
            timeout: Duration(seconds: 1));
        socketListener(_secureSocket);
        var response = await readResponse();
        if (response == '@') {
          print('Secure Socket is open for Root Server');
        }
        isRootServerStarted =
            await _lookupForSecondaryAddress(_secureSocket, atSign, rootServer);
        if (isRootServerStarted) {
          print('Root server started successfully');
          _secureSocket.close();
          break;
        } else {
          print('Root server is not completely initialized');
          _secureSocket.close();
          retryCount = retryCount + 1;
          await Future.delayed(Duration(seconds: 5));
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
    expect(isRootServerStarted, true, reason: 'Failed to start root server successfully');
  }, timeout: Timeout(Duration(minutes: 1)));
}

Future<bool> _lookupForSecondaryAddress(
    SecureSocket _secureSocket, String atSign, String rootServer) async {
  _secureSocket.write('$atSign\n');
  var response = await readResponse();
  if (response.toString().startsWith(rootServer)) {
    print('Root Server is up and running');
    return true;
  } else {
    print(
        'Unable to fetch the secondary address of $atSign. Perhaps root server not initialized successfully');
    return false;
  }
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
  var retryCount = 0;
  while (rootServerResponseQueue.isEmpty || retryCount < maxRetryCount) {
    await Future.delayed(Duration(milliseconds: 5));
    retryCount = retryCount + 1;
  }
  if (rootServerResponseQueue.isNotEmpty) {
    return rootServerResponseQueue.removeFirst();
  }
}
