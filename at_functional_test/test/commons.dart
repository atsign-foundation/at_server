import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pkam_utils.dart';

var response;
var from_key;

///Socket Connection
Future<Socket> socket_connection(host, port) async {
  return await Socket.connect(host, port);
}

///Secure Socket Connection
Future<SecureSocket> secure_socket_connection(host, port) async {
  var socket = await SecureSocket.connect(host, port);
  return socket;
}

/// Socket Listener
void socket_listener(Socket socket) {
  socket.listen((data) async {
    // Setting response to null to clear the result of previous execution
    response = null;
    response = utf8.decode(data);
    if (response.contains('data:')) {
      var from_resp = response.split('data:');
      from_key = from_resp[1].substring(0, from_resp[1].length - 2);
    }
  });
}

/// Socket write
Future<void> socket_writer(Socket socket, String msg) async {
  socket.write(msg + '\n');
  await Future.delayed(Duration(seconds: 2));
}

///The prepare function takes a socket and atsign as input params and runs a from verb and pkam verb on the atsign param.
Future<void> prepare(Socket socket, String atsign) async {
  // FROM VERB
  await socket_writer(socket, 'from:$atsign');
  print('From verb response $response');
  expect(response, contains(from_key));
  response = response.replaceAll('data:', '');
  response = response.substring(0, response.length - 2).trim();
  var pkam_digest = generatePKAMDigest(atsign, response);

  // PKAM VERB
  await socket_writer(socket, 'pkam:$pkam_digest');
  await Future.delayed(Duration(seconds: 5));
  print('pkam verb response $response');
  expect(response, 'data:success\n$atsign@');
}
