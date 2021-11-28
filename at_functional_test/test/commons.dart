import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'pkam_utils.dart';

var _queue = Queue();
var maxRetryCount = 10;
var retryCount = 1;

///Socket Connection
Future<Socket> socketConnection(host, port) async {
  return await Socket.connect(host, port);
}

///Secure Socket Connection
Future<SecureSocket> secureSocketConnection(host, port) async {
  SecureSocket socket;
  while (true) {
    try {
      socket = await SecureSocket.connect(host, port);
      if (retryCount > maxRetryCount) {
        break;
      }
    } on Exception {
      print('retrying for connection.. $retryCount');
      await Future.delayed(Duration(seconds: 5));
      retryCount++;
    }
  }
  return socket;
}

/// Socket Listener
void socketListener(Socket socket) {
  socket.listen(_messageHandler);
}

/// Socket write
Future<void> socketWriter(Socket socket, String msg) async {
  msg = msg + '\n';
  // print('command sent: $msg');
  socket.write(msg);
}

///The prepare function takes a socket and atsign as input params and runs a from verb and pkam verb on the atsign param.
Future<void> prepare(Socket socket, String atsign) async {
  // FROM VERB
  await socketWriter(socket, 'from:$atsign');
  var response = await read();
  print('From verb response $response');
  response = response.replaceAll('data:', '');
  //var pkam_digest = generatePKAMDigest(atsign, response);
  var cram = getDigest(atsign, response);

  // PKAM VERB
  // await socket_writer(socket, 'pkam:$pkam_digest');
  // response = await read();
  // print('pkam verb response $response');
  // expect(response, 'data:success\n');

  //CRAM VERB
  await socketWriter(socket, 'cram:$cram');
  response = await read();
  print('cram verb response $response');
  // expect(response, 'data:success\n');
}

void _messageHandler(data) {
  if (data.length == 1 && data.first == 64) {
    return;
  }
  //ignore prompt(@ or @<atSign>@) after '\n'. byte code for \n is 10
  if (data.last == 64 && data.contains(10)) {
    data = data.sublist(0, data.lastIndexOf(10) + 1);
    _queue.add(utf8.decode(data));
  } else if (data.length > 1 && data.first == 64 && data.last == 64) {
    // pol responses do not end with '\n'. Add \n for buffer completion
    _queue.add(utf8.decode(data));
  } else {
    _queue.add(utf8.decode(data));
  }
}

Future<String> read({int maxWaitMilliSeconds = 5000}) async {
  // ignore: prefer_typing_uninitialized_variables
  var result;
  //wait maxWaitMilliSeconds seconds for response from remote socket
  var loopCount = (maxWaitMilliSeconds / 50).round();
  for (var i = 0; i < loopCount; i++) {
    await Future.delayed(Duration(milliseconds: 100));
    var queueLength = _queue.length;
    if (queueLength > 0) {
      result = _queue.removeFirst();
      // result from another secondary is either data or a @<atSign>@ denoting complete
      // of the handshake
      if (result.startsWith('data:') ||
          (result.startsWith('@') && result.endsWith('@'))) {
        return result;
      } else {
        //log any other response and ignore
        result = '';
      }
    }
  }
  return result;
}
