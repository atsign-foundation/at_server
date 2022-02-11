import 'package:at_commons/at_commons.dart';
import 'pkam_utils.dart';

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';


const int maxRetryCount = 10;

class SimpleOutboundSocketHandler {

  late Queue queue;

  // ignore: prefer_typing_uninitialized_variables
  String host;
  int port;
  String atSign;
  SecureSocket? socket;

  /// Try to open a socket
  SimpleOutboundSocketHandler(this.host, this.port, this.atSign) {
    queue = Queue();
  }

  Future<void> connect() async {
    int retryCount = 1;
    while (retryCount < maxRetryCount) {
      try {
        socket = await SecureSocket.connect(host, port);
        if (socket != null) {
          return;
        }
      } on Exception {
        print('retrying "$host:$port" for connection.. $retryCount');
        await Future.delayed(Duration(seconds: 1));
        retryCount++;
      }
    }
    throw Exception("Failed to connect to $host:$port after $retryCount attempts");
  }

  void startListening() {
    socket!.listen(_messageHandler);
  }

  /// Socket write
  Future<void> writeCommand(String command) async {
    command = command + '\n';
    print('command sent: $command');
    socket!.write(command);
  }

  /// Runs a from verb and pkam verb on the atsign param.
  Future<void> sendFromAndPkam() async {
    // FROM VERB
    await writeCommand('from:$atSign');
    var response = await read(to:2000);
    response = response.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(atSign, response);

    // PKAM VERB
    await writeCommand('pkam:$pkamDigest');
    response = await read(to:1000);
    print('pkam verb response $response');
    expect(response, 'data:success\n');
  }

  Future<void> clear() async {
    // queue.clear();
  }

  void _messageHandler(data) {
    if (data.length == 1 && data.first == 64) {
      return;
    }
    //ignore prompt(@ or @<atSign>@) after '\n'. byte code for \n is 10
    if (data.last == 64 && data.contains(10)) {
      data = data.sublist(0, data.lastIndexOf(10) + 1);
      queue.add(utf8.decode(data));
    } else if (data.length > 1 && data.first == 64 && data.last == 64) {
      // pol responses do not end with '\n'. Add \n for buffer completion
      queue.add(utf8.decode(data));
    } else {
      queue.add(utf8.decode(data));
    }
  }

  Future<String> read({int to = 2000}) async {
    String result;
    //wait maxWaitMilliSeconds seconds for response from remote socket
    var loopDelay=50;
    var loopCount = (to / loopDelay).round();
    for (var i = 0; i < loopCount; i++) {
      await Future.delayed(Duration(milliseconds: loopDelay));
      var queueLength = queue.length;
      if (queueLength > 0) {
        result = queue.removeFirst();
        // result from another secondary is either data or a @<atSign>@ denoting complete
        // of the handshake
        if (result.startsWith('data:') ||
            (result.startsWith('error:')) ||
            (result.startsWith('@') && result.endsWith('@'))) {
          return result;
        } else {
          // Any other response is unexpected and bad
          throw AtConnectException("Unexpected response '$result' from $host:$port ($atSign)");
        }
      }
    }
    throw AtTimeoutException ("No response from $host:$port ($atSign)");
  }
}
