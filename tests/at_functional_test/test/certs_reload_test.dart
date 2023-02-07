import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:test/test.dart';

import 'functional_test_commons.dart';

log (prefix, command, response) {
  print('${prefix}SENT ${command.padRight(45)} RCVD $response');
}

void main() async {
  var atSign = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  var host = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
  var port = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];
  Socket socket = await secure_socket_connection(host, port);
  socket_listener(socket);
  bool prepared = false;

  setUp(() async {
    if (! prepared) {
      await prepare(socket, atSign);
      prepared = true;
    }
  });

  test('test shouldReloadCertificates config', () async {
    String command, response;

    command = 'config:set:shouldReloadCertificates=true';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    command = 'config:print:shouldReloadCertificates';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:true\n');
  });

  test('test checkCertificateReload config', () async {
    String command, response;

    // delete the restart file if it is present
    command = 'config:set:shouldReloadCertificates=false';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    command = 'config:set:checkCertificateReload=false';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    command = 'config:print:checkCertificateReload';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:false\n');

    command = 'config:set:checkCertificateReload=true';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    // We haven't created a 'restart' file (via config:set:shouldReloadCertificates=true)
    // so nothing should have happened, and we should get a response here
    command = 'info:brief';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, startsWith('data:{"version":'));
  });

  test('test soft restart', () async {
    String command, response;

    /// Create the 'restart' file to indicate that the server should restart
    command = 'config:set:shouldReloadCertificates=true';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    /// Tell the server to check if it should soft restart (it should immediately do so)
    command = 'config:set:checkCertificateReload=true';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'data:ok\n');

    /// Try to send any other command to the server - should fail with appropriate error message
    /// and close the socket.
    command = 'config:print:checkCertificateReload';
    await socket_writer(socket, command);
    response = await read();
    log('', command, response);
    expect(response, 'error:'
        '{"errorCode":"AT0024","errorDescription":"Server is paused : Server is temporarily'
        ' paused and should be available again shortly"}'
        '\n');

    /// Immediately try to reconnect; should fail
    socket = await secure_socket_connection(host, port);
    socket_listener(socket);
    command = 'info:brief';
    await socket_writer(socket, command);
    response = await read(maxWaitMilliSeconds: 100);
    log('', command, response);
    // Note that the response should not be JSON because we haven't sent a 'from' with our config
    // so the server assumes we are an old client, unable to handle JSON error responses
    expect(response, 'error:AT0024-Exception: Server is temporarily'
        ' paused and should be available again shortly\n');

    /// The server will check every second if it can restart (no active connections).
    /// so let's wait for a few seconds longer, to allow for a slow VM here, and then
    /// we should be able to connect
    await Future.delayed(Duration(milliseconds: 5500));
    socket = await secure_socket_connection(host, port);
    socket_listener(socket);
    command = 'info:brief';
    await socket_writer(socket, command);
    response = await read(maxWaitMilliSeconds: 100);
    log('', command, response);
    expect(response, startsWith('data:{"version":'));
  });
}
