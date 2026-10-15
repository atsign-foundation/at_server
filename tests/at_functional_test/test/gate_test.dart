import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:at_lookup/at_lookup.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// The gate's scenarios that need two real atServers, each under its title.
///
/// @xavier plays @alice and @jeremy plays the other atSign. No other test in
/// this pack uses either, so the gate state each test leaves cannot reach
/// them, and every test works in namespaces of its own.
void main() {
  const String xavier = '@xavier';
  const String jeremy = '@jeremy';
  const String rootDomain = 'vip.ve.atsign.zone';
  final int rootPort =
      int.tryParse(Platform.environment['VIRTUALENV_BASE_PORT'] ?? '') ?? 64;

  late SecondaryAddress xavierAddress;
  late OutboundConnectionFactory xavierClient;
  late OutboundConnectionFactory jeremyClient;
  late String ns;

  Future<SecondaryAddress> addressOf(String atSign) =>
      CacheableSecondaryAddressFinder(rootDomain, rootPort)
          .findSecondary(atSign);

  Future<OutboundConnectionFactory> clientOf(String atSign) async {
    final SecondaryAddress address = await addressOf(atSign);
    final OutboundConnectionFactory client = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, address.host, address.port);
    expect(await client.authenticateConnection(), 'data:success',
        reason: 'the client of $atSign must authenticate');
    return client;
  }

  Future<String> send(OutboundConnectionFactory client, String command) async =>
      (await client.sendRequestToServer(command)).trim();

  /// The status of notification [id] once it stops being queued, or the last
  /// one seen after 30 seconds.
  Future<String> settledStatus(
      OutboundConnectionFactory sender, String id) async {
    String status = '';
    for (int i = 0; i < 120; i++) {
      status = (await send(sender, 'notify:status:$id'))
          .replaceFirst('data:', '');
      if (status != 'queued' && status != 'errored') {
        return status;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return status;
  }

  /// Sends a notification from [sender] with a fresh id, and answers the id.
  Future<String> notifies(
      OutboundConnectionFactory sender, String recipientAndKey) async {
    final String id = Uuid().v4();
    expect(await send(sender, 'notify:id:$id:$recipientAndKey'), 'data:$id');
    return id;
  }

  setUpAll(() async {
    xavierAddress = await addressOf(xavier);
    xavierClient = await clientOf(xavier);
    jeremyClient = await clientOf(jeremy);
  });

  tearDownAll(() async {
    await xavierClient.close();
    await jeremyClient.close();
  });

  setUp(() => ns = 'g${Uuid().v4().replaceAll('-', '').substring(0, 10)}');

  tearDown(() async {
    for (final OutboundConnectionFactory client in [xavierClient, jeremyClient]) {
      expect(await send(client, 'gate:default:ungated'), 'data:success');
    }
  });

  /// A connection to @xavier's atServer presenting the virtualenv's client
  /// certificate, as every atServer in it does to another.
  Future<(SecureSocket, Future<String> Function())> asAnAtServer() async {
    const String certs = '../../tools/build_virtual_environment/ve_base/'
        'contents/atsign/secondary/base/certs/mtls';
    final SecureSocket socket = await SecureSocket.connect(
        xavierAddress.host, xavierAddress.port,
        context: SecurityContext(withTrustedRoots: true)
          ..useCertificateChain('$certs/fullchain.pem')
          ..usePrivateKey('$certs/privkey.pem'));
    final StreamController<String> lines = StreamController<String>();
    String pending = '';
    socket.listen((data) {
      pending += utf8.decode(data);
      int end;
      while ((end = pending.indexOf('\n')) != -1) {
        lines.add(pending.substring(0, end).trim());
        pending = pending.substring(end + 1);
      }
      // NOTE a prompt ends an answer without a newline, and pol's answer is
      // the prompt it opens.
      if (RegExp(r'^@?[^\s:@]*@$').hasMatch(pending.trim())) {
        if (pending.trim() != '@') {
          lines.add(pending.trim());
        }
        pending = '';
      }
    });
    final StreamIterator<String> answers = StreamIterator(lines.stream);
    Future<String> next() async {
      await answers.moveNext().timeout(const Duration(seconds: 30));
      final String line = answers.current;
      return RegExp(r'^@(data|error):').hasMatch(line) ? line.substring(1) : line;
    }

    return (socket, next);
  }

  test('Authentication is never gated', () async {
    expect(await send(xavierClient, 'gate:default:closed'), 'data:success');
    final String signingKey =
        (await send(jeremyClient, 'llookup:$jeremy:signing_privatekey$jeremy'))
            .replaceFirst('data:', '');
    final (SecureSocket socket, Future<String> Function() next) =
        await asAnAtServer();
    socket.write('from:$jeremy\n');
    final String proof = await next();
    expect(proof, startsWith('data:proof:'));
    final List<String> sessionAndChallenge =
        proof.substring('data:proof:'.length).split(':');
    final String cookie = 'public:${sessionAndChallenge[0]}';
    expect(
        await send(
            jeremyClient,
            'update:$cookie '
            '${AuthenticationUtils.generatePKAMDigest(signingKey, sessionAndChallenge[1])}'),
        startsWith('data:'));
    socket.write('pol\n');
    expect(await next(), '$jeremy@');
    await socket.close();
    await send(jeremyClient, 'delete:$cookie');
  }, timeout: Timeout(Duration(minutes: 2)));

  test('A sending atServer discards a refused notification at once', () async {
    expect(await send(xavierClient, 'gate:rule:$ns:open:limit:1'),
        'data:success');
    final String accepted =
        await notifies(jeremyClient, '$xavier:a.$ns$jeremy');
    expect(await settledStatus(jeremyClient, accepted), 'delivered');
    final String refused = await notifies(jeremyClient, '$xavier:b.$ns$jeremy');
    expect(await settledStatus(jeremyClient, refused), 'refused');
    await Future.delayed(const Duration(seconds: 3));
    expect(await send(jeremyClient, 'notify:status:$refused'), 'data:refused',
        reason: 'a refused notification is not tried again');
  });

  test('A refusal does not hold back the next notification', () async {
    expect(await send(xavierClient, 'gate:rule:$ns:closed'), 'data:success');
    expect(await send(xavierClient, 'gate:rule:open$ns:open'), 'data:success');
    final String refused = await notifies(jeremyClient, '$xavier:a.$ns$jeremy');
    final String next =
        await notifies(jeremyClient, '$xavier:b.open$ns$jeremy');
    final Stopwatch sinceSent = Stopwatch()..start();
    expect(await settledStatus(jeremyClient, next), 'delivered');
    expect(sinceSent.elapsed, lessThan(const Duration(seconds: 10)));
    expect(await settledStatus(jeremyClient, refused), 'refused');
  });

  test('The reply to an invitation arrives in quarantine', () async {
    for (final OutboundConnectionFactory client in [xavierClient, jeremyClient]) {
      expect(await send(client, 'gate:rule:$ns:closed'), 'data:success');
      expect(await send(client, 'gate:rule:invitations.$ns:open'),
          'data:success');
    }
    final String invitation =
        await notifies(xavierClient, '$jeremy:inv1.invitations.$ns$xavier');
    expect(await settledStatus(xavierClient, invitation), 'delivered');
    final String reply =
        await notifies(jeremyClient, '$xavier:inv1.invitations.$ns$jeremy');
    expect(await settledStatus(jeremyClient, reply), 'delivered');
    expect(
        await send(xavierClient, 'gate:check:invitations.$ns:$jeremy'),
        'data:{"namespace":"invitations.$ns","atSign":"$jeremy",'
        '"verdict":"quarantined"}');
  });

  test('Accepting an invitation is the application admitting the atSign',
      () async {
    expect(await send(xavierClient, 'gate:rule:$ns:closed'), 'data:success');
    expect(await send(xavierClient, 'gate:rule:invitations.$ns:open'),
        'data:success');
    final String quarantined =
        await notifies(jeremyClient, '$xavier:inv1.invitations.$ns$jeremy');
    expect(await settledStatus(jeremyClient, quarantined), 'delivered');
    expect(await send(xavierClient, 'gate:admit:$ns:$jeremy'), 'data:success');
    final String message =
        await notifies(xavierClient, '$jeremy:msg.$ns$xavier');
    expect(await settledStatus(xavierClient, message), 'delivered');
  });

  /// What a monitor of @xavier's, asking for quarantined notifications when
  /// [quarantined], receives within 10 seconds of starting, replaying from
  /// [since].
  Future<String> monitored(int since, {required bool quarantined}) async {
    final StringBuffer received = StringBuffer();
    final SecureSocket socket =
        await SecureSocket.connect(xavierAddress.host, xavierAddress.port);
    bool pkamSent = false;
    bool monitorSent = false;
    socket.listen((data) {
      received.write(utf8.decode(data));
      final String all = received.toString();
      if (!pkamSent && all.contains('data:_')) {
        pkamSent = true;
        final int start = all.indexOf('data:_') + 'data:'.length;
        final int end = all.indexOf('\n', start);
        final String challenge =
            all.substring(start, end == -1 ? all.length : end).trim();
        socket.write('pkam:${AuthenticationUtils.generatePKAMDigest(
            pkamPrivateKeyMap[xavier]!, challenge)}\n');
      } else if (pkamSent && !monitorSent && all.contains('data:success')) {
        monitorSent = true;
        socket.write('monitor${quarantined ? ':quarantined' : ''}:$since\n');
      }
    });
    socket.write('from:$xavier\n');
    await Future.delayed(const Duration(seconds: 10));
    await socket.close();
    expect(received.toString(), contains('data:success'),
        reason: 'the monitor connection must authenticate');
    return received.toString();
  }

  /// Notifications from @jeremy to @xavier, one from quarantine and one in a
  /// namespace that admits @jeremy, both delivered; answers their ids.
  Future<(String, String)> quarantinedAndAdmitted() async {
    expect(await send(xavierClient, 'gate:rule:invitations.$ns:open'),
        'data:success');
    expect(await send(xavierClient, 'gate:rule:$ns:closed:admit:$jeremy'),
        'data:success');
    final String fromQuarantine =
        await notifies(jeremyClient, '$xavier:inv.invitations.$ns$jeremy');
    final String admitted = await notifies(jeremyClient, '$xavier:msg.$ns$jeremy');
    for (final String id in [fromQuarantine, admitted]) {
      expect(await settledStatus(jeremyClient, id), 'delivered');
    }
    return (fromQuarantine, admitted);
  }

  test('A client that asks receives quarantined notifications, marked',
      () async {
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    final (String fromQuarantine, String admitted) =
        await quarantinedAndAdmitted();
    final String received = await monitored(since, quarantined: true);
    final List<Map<String, dynamic>> notifications = [
      for (final String line in received.split('\n'))
        if (line.startsWith('notification: '))
          jsonDecode(line.substring('notification: '.length))
    ];
    final Map<String, dynamic> marked =
        notifications.singleWhere((n) => n['id'] == fromQuarantine);
    expect(marked['quarantined'], true);
    expect(notifications.where((n) => n['id'] == admitted), hasLength(1),
        reason: 'the control: the monitor delivers what it was sent');
  }, timeout: Timeout(Duration(minutes: 2)));

  test('A client that does not ask is never sent a quarantined notification',
      () async {
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    final (String fromQuarantine, String admitted) =
        await quarantinedAndAdmitted();
    final String received = await monitored(since, quarantined: false);
    expect(received, contains(admitted),
        reason: 'the control: the monitor delivers what it was sent');
    expect(received, isNot(contains(fromQuarantine)));
  }, timeout: Timeout(Duration(minutes: 2)));

  test(
      'A key shared with an atSign the namespace refuses is stored, and not'
      ' notified', () async {
    final int since = DateTime.now().toUtc().millisecondsSinceEpoch - 1000;
    expect(await send(xavierClient, 'gate:rule:$ns:closed:admit:@curtly'),
        'data:success');
    expect(int.tryParse((await send(
            xavierClient, 'update:$jeremy:status.$ns$xavier v'))
        .replaceFirst('data:', '')), isNotNull);
    expect(await send(xavierClient, 'llookup:$jeremy:status.$ns$xavier'),
        'data:v');
    await Future.delayed(const Duration(seconds: 3));
    expect(
        await send(jeremyClient, 'notify:list:$since'),
        isNot(contains('status.$ns')));
  });

  test('A stored key becomes reachable when its atSign is admitted', () async {
    expect(await send(xavierClient, 'gate:rule:$ns:closed:admit:@curtly'),
        'data:success');
    await send(xavierClient, 'update:$jeremy:status.$ns$xavier v');
    expect(await send(xavierClient, 'gate:admit:$ns:$jeremy'), 'data:success');
    expect(
        await send(jeremyClient, 'lookup:bypassCache:true:status.$ns$xavier'),
        'data:v');
  });

  test('A refused cache refresh removes the cached copy', () async {
    expect(await send(xavierClient, 'gate:rule:$ns:closed:admit:$jeremy'),
        'data:success');
    await send(xavierClient, 'update:ttr:1:$jeremy:status.$ns$xavier v');
    expect(await send(jeremyClient, 'lookup:status.$ns$xavier'), 'data:v');
    final String copy = 'cached:$jeremy:status.$ns$xavier';
    expect(await send(jeremyClient, 'llookup:$copy'), 'data:v',
        reason: "@jeremy's atServer must hold the copy before the refresh");
    expect(await send(xavierClient, 'gate:remove:$ns:$jeremy'), 'data:success');
    await Future.delayed(const Duration(seconds: 2));
    expect(await send(jeremyClient, 'llookup:$copy'), 'data:v',
        reason: 'the copy outlives its ttr until a refresh replaces it');
    expect(await send(jeremyClient, 'config:set:doCacheRefreshNow=true'),
        'data:ok');
    String held = '';
    for (int i = 0; i < 60; i++) {
      held = await send(jeremyClient, 'llookup:$copy');
      if (!held.startsWith('data:')) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    expect(held, contains('AT0015'),
        reason: "the refresh must remove @jeremy's copy");
  });
}
