import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';

log(prefix, command, response) {
  print('${prefix}SENT ${command.padRight(45)} RCVD $response');
}

void main() async {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(atSign, host, port);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  test('test shouldReloadCertificates config', () async {
    String command, response;

    command = 'config:set:shouldReloadCertificates=true';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    command = 'config:print:shouldReloadCertificates';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:true');
  });

  test('test checkCertificateReload config', () async {
    String command, response;

    // delete the restart file if it is present
    command = 'config:set:shouldReloadCertificates=false';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    command = 'config:set:checkCertificateReload=false';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    command = 'config:print:checkCertificateReload';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:false');

    command = 'config:set:checkCertificateReload=true';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    // We haven't created a 'restart' file (via config:set:shouldReloadCertificates=true)
    // so nothing should have happened, and we should get a response here
    command = 'info:brief';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, startsWith('data:{"version":'));
  });

  test('test soft restart', () async {
    String command, response;

    /// Create the 'restart' file to indicate that the server should restart
    command = 'config:set:shouldReloadCertificates=true';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    /// Tell the server to check if it should soft restart (it should immediately do so)
    command = 'config:set:checkCertificateReload=true';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:ok');

    /// Try to send any other command to the server - should fail with appropriate error message
    /// and close the socket.
    command = 'config:print:checkCertificateReload';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(
        response,
        'error:'
        '{"errorCode":"AT0024","errorDescription":"Server is paused : Server is temporarily'
        ' paused and should be available again shortly"}');

    /// Immediately try to reconnect; should fail
    await firstAtSignConnection.initiateConnectionWithListener(atSign, host, port);
    command = 'info:brief';
    response = await firstAtSignConnection.sendRequestToServer(command,
        maxWaitMilliSeconds: 100);
    log('', command, response);
    // Note that the response should not be JSON because we haven't sent a 'from' with our config
    // so the server assumes we are an old client, unable to handle JSON error responses
    expect(
        response,
        'error:AT0024-Exception: Server is temporarily'
        ' paused and should be available again shortly');
    await firstAtSignConnection.close();

    /// The server will check every second if it can restart (no active connections).
    /// so let's wait for a few seconds longer, to allow for a slow VM here, and then
    /// we should be able to connect
    await Future.delayed(Duration(milliseconds: 5500));
    await firstAtSignConnection.initiateConnectionWithListener(atSign, host, port);
    command = 'info:brief';
    response = await firstAtSignConnection.sendRequestToServer(command,
        maxWaitMilliSeconds: 1000);
    log('', command, response);
    expect(response, startsWith('data:{"version":'));
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });
}
