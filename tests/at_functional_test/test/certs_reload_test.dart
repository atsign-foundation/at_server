import 'dart:convert';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void log(String prefix, String command, String response) {
  print('$prefix SENT ${command.padRight(45)} RCVD $response');
}

/// The commit id out of a `stats:3` response.
///
/// `stats` returns a list of `{"id":..,"name":..,"value":..}`, and `value` is
/// itself a JSON string, so it needs decoding twice. Whether the inner decode
/// yields an int or a String is a property of the server's encoder, not
/// something to guess at from the outside, so this accepts either. Parsing the
/// inner value directly as a String compiles cleanly whatever it is, because
/// `jsonDecode` returns `dynamic`, and throws at runtime on the int branch.
int commitIdFromStats(String statsResponse) {
  final stats = jsonDecode(statsResponse.replaceAll('data:', '').trim());
  final value = jsonDecode(stats[0]['value'].toString());
  return value is int ? value : int.parse(value.toString());
}

void main() async {
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String atSign = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String host = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int port = ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  setUp(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        atSign, host, port);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'Authentication failed when executing test');
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

    /// A soft restart must come back on the SAME storage. It is an in-process
    /// stop()/start() rather than a new container, so the whole persistence
    /// stack is torn down and rebuilt from config while the process lives —
    /// and a defect that re-roots it (a storage path that resolves to the
    /// working directory, a cached bundle answering for another location)
    /// throws nothing. The server comes back up looking healthy and serving an
    /// empty store. Only records written before the restart and read after it
    /// can tell the difference, so write one into each of the three stores
    /// that are rebuilt independently, under a run-unique id.
    final String uniqueId = Uuid().v4().hashCode.toString();
    final String keyName = 'restart-probe-$uniqueId';
    final String keyValue = 'value-$uniqueId';

    /// 1. Keystore, and with it the commit log.
    command = 'update:public:$keyName$atSign $keyValue';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, startsWith('data:'),
        reason: 'the record this test is about must actually be created, or '
            'the assertion after the restart proves nothing');

    /// 2. The commit log's own sequence, which lives in a separate box under a
    /// separate path and so can be re-rooted on its own. A sequence that
    /// restarted from zero would make every client resync from scratch.
    command = 'stats:3';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    final int commitIdBeforeRestart = commitIdFromStats(response);

    /// 3. Notification keystore — a third box, a third path.
    command =
        'notify:update:messageType:key:ttr:-1:$atSign:$keyName$atSign:$keyValue';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, startsWith('data:'),
        reason: 'the notification must be accepted before the restart, or its '
            'absence afterwards would say nothing');

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
    await firstAtSignConnection.initiateConnectionWithListener(
        atSign, host, port);
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
    await Future.delayed(Duration(seconds: 5));
    bool connected = false;
    while (!connected) {
      try {
        await firstAtSignConnection.initiateConnectionWithListener(
            atSign, host, port);
        command = 'info:brief';
        response = await firstAtSignConnection.sendRequestToServer(command,
            maxWaitMilliSeconds: 1000);
        log('', command, response);
        expect(response, startsWith('data:{"version":'));
        connected = true;
      } catch (e) {
        log('', command, response);
        await Future.delayed(Duration(seconds: 2));
      }
    }

    /// The server is back. Everything below is deliberately OUTSIDE the
    /// reconnect loop above, whose `catch` would otherwise swallow a failed
    /// expectation and retry it until the loop happened to pass.
    ///
    /// This is the part that proves the restart came back on the same storage
    /// rather than merely coming back.
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'the assertions below need an authenticated connection, so a '
            'failure here must not be read as the records being gone');

    /// 1. The keystore record, by VALUE. A fresh store would answer
    /// "key not found"; a store rooted elsewhere would too.
    command = 'llookup:public:$keyName$atSign';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, 'data:$keyValue',
        reason: 'a record written before the restart must still be readable '
            'after it, with the value it was written with — that is what '
            'makes this the same storage and not a new one');

    /// 2. The commit log carried on rather than starting again.
    command = 'stats:3';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    final int commitIdAfterRestart = commitIdFromStats(response);
    expect(commitIdAfterRestart, greaterThanOrEqualTo(commitIdBeforeRestart),
        reason: 'the commit log is a separate box under a separate path; a '
            'sequence that went backwards would mean it was rebuilt empty, '
            'and every client would resync the whole atSign');

    /// 3. The notification, still in its own store.
    command = 'notify:list';
    response = await firstAtSignConnection.sendRequestToServer(command);
    log('', command, response);
    expect(response, contains(keyName),
        reason: 'the notification keystore is the third of three stores torn '
            'down and rebuilt by the restart, and it can be re-rooted '
            'independently of the other two');
  });

  tearDown(() async {
    await firstAtSignConnection.close();
  });
}
