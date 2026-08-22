// Cross-atServer coverage for the at_commons 5.10.0 protocol enhancements
// (#2678): the four timestamps survive the hop between two real atServers.
//
//   * a notification carrying cAt/uAt/eAt stores the RECEIVER's cached key
//     with the origin's values — on first cache and on refresh
//   * a delete:dAt propagates: the receiver's cached-key DELETE commit
//     entry records the origin deletion time (visible via scan:cl)
//
// Both tests skip (visibly, via markTestSkipped) when either atServer
// predates the capability: every deployed server PARSES the syntax (it
// rolled out ahead of this), so the probe must test behaviour, not grammar —
// scan:cl returns a list of maps on a capable server and falls through to a
// plain scan (a list of strings) on one that ignores the :cl flag.

import 'dart:convert';

import 'package:test/test.dart';

import 'e2e_test_utils.dart' as e2e;
import 'notify_verb_test.dart' as notification;

void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;

  int lastValue = DateTime.now().millisecondsSinceEpoch;

  const cAtWire = '2020-01-02T03:04:05.678000Z';
  const cAtJson = '2020-01-02 03:04:05.678Z';
  const uAtWire = '2021-02-03T04:05:06.789000Z';
  const uAtJson = '2021-02-03 04:05:06.789Z';
  const uAt2Wire = '2021-06-01T12:00:00.000000Z';
  const uAt2Json = '2021-06-01 12:00:00.000Z';
  const dAtWire = '2023-05-05T11:59:44.123000Z';
  const eAtWire = '2030-01-01T00:00:00.000000Z';
  const eAtJson = '2030-01-01 00:00:00.000Z';

  /// Sends [command] on [sh] every 500ms until [done] accepts the response
  /// or [timeoutMillis] elapses; returns the last response either way, so a
  /// timeout surfaces as a normal assertion failure on real observed state.
  Future<String> pollUntil(e2e.SimpleOutboundConnection sh, String command,
      bool Function(String response) done,
      {int timeoutMillis = 30000}) async {
    final deadline = DateTime.now().add(Duration(milliseconds: timeoutMillis));
    String response = '';
    while (DateTime.now().isBefore(deadline)) {
      await sh.writeCommand(command);
      response = await sh.read();
      if (done(response)) {
        return response;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    return response;
  }

  /// Whether the atServer behind [sh] implements scan:cl (the probe for the
  /// whole 5.10.0 feature set: it lands in the same release). Seeds a key
  /// first so the response is never an empty list, which would be
  /// indistinguishable between the two behaviours. A failed seed is a rig
  /// failure and throws — it must not read as 'predates the feature'.
  Future<bool> supportsProtocolEnhancements(
      e2e.SimpleOutboundConnection sh, String atSign) async {
    await sh.writeCommand('update:capprobe-$lastValue.e2e$atSign probe');
    final seedResponse = await sh.read();
    if (!RegExp(r'^data:-?\d+$').hasMatch(seedResponse.trim())) {
      throw StateError('capability-probe seed update on $atSign failed:'
          ' $seedResponse');
    }
    await sh.writeCommand('scan:cl capprobe-$lastValue');
    final response = await sh.read();
    if (!response.startsWith('data:')) {
      return false;
    }
    final decoded = jsonDecode(response.replaceAll('data:', ''));
    return decoded is List && decoded.isNotEmpty && decoded.first is Map;
  }

  late bool bothSidesCapable;

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
    bothSidesCapable = await supportsProtocolEnhancements(sh1, atSign_1) &&
        await supportsProtocolEnhancements(sh2, atSign_2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    sh1.clear();
    sh2.clear();
  });

  test('a notification carrying cAt/uAt stores the cached key with the '
      'origin values; a refresh updates them', () async {
    if (!bothSidesCapable) {
      markTestSkipped('an atServer in this pairing predates the 5.10.0 '
          'protocol enhancements');
      return;
    }
    var key = 'tskey-$lastValue';
    var value = 'ts-value-$lastValue';

    await sh1.writeCommand('notify:update:ttl:600000:ttr:-1'
        ':cAt:$cAtWire:uAt:$uAtWire'
        ':$atSign_2:$key$atSign_1:$value');
    String response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 60000);

    // Delivery confirms the wire hop; poll for receive-side processing.
    response = await pollUntil(
        sh2,
        'llookup:all:cached:$atSign_2:$key$atSign_1',
        (r) => r.startsWith('data:'));
    Map metaData = jsonDecode(response.replaceAll('data:', ''))['metaData'];
    expect(metaData['createdAt'], cAtJson,
        reason: 'the cached copy must carry the ORIGIN\'s createdAt, not '
            'one stamped on the receiving server\'s clock');
    expect(metaData['updatedAt'], uAtJson);

    // Refresh with a newer uAt; the cached copy adopts it.
    await sh1.writeCommand('notify:update:ttl:600000:ttr:-1'
        ':cAt:$cAtWire:uAt:$uAt2Wire'
        ':$atSign_2:$key$atSign_1:$value-2');
    response = await sh1.read();
    notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 60000);

    response = await pollUntil(
        sh2,
        'llookup:all:cached:$atSign_2:$key$atSign_1',
        (r) =>
            r.startsWith('data:') &&
            jsonDecode(r.replaceAll('data:', ''))['metaData']['updatedAt'] ==
                uAt2Json);
    metaData = jsonDecode(response.replaceAll('data:', ''))['metaData'];
    expect(metaData['updatedAt'], uAt2Json,
        reason: 'a refresh notification transmits the origin\'s newer '
            'updatedAt and the cached copy adopts it');
    expect(metaData['createdAt'], cAtJson);
  }, timeout: Timeout(Duration(seconds: 180)));

  test('delete:dAt propagates: the receiver\'s cached-key DELETE entry '
      'records the origin deletion time', () async {
    if (!bothSidesCapable) {
      markTestSkipped('an atServer in this pairing predates the 5.10.0 '
          'protocol enhancements');
      return;
    }
    var key = 'delkey-$lastValue';
    var value = 'del-value-$lastValue';

    // Cache the key on atSign_2 with cascade delete, via autoNotify.
    await sh1.writeCommand(
        'update:ttr:100000:ccd:true:$atSign_2:$key$atSign_1 $value');
    String response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // autoNotify returns no notification id, so poll for the cached copy.
    response = await pollUntil(sh2, 'llookup:cached:$atSign_2:$key$atSign_1',
        (r) => r.contains('data:$value'));
    expect(response, contains('data:$value'),
        reason: 'the cached key must exist before the delete propagates');

    // Delete with an asserted deletion time.
    await sh1.writeCommand('delete:dAt:$dAtWire:$atSign_2:$key$atSign_1');
    response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    response = await pollUntil(sh2, 'llookup:cached:$atSign_2:$key$atSign_1',
        (r) => r.contains('does not exist in keystore'));
    expect(response, contains('does not exist in keystore'),
        reason: 'ccd:true means the cascade delete removes the cached copy');

    // The receiver's DELETE commit entry carries the origin deletion time.
    await sh2.writeCommand('scan:cl $key');
    response = await sh2.read();
    final List entries = jsonDecode(response.replaceAll('data:', ''));
    final Map entry = entries
        .cast<Map>()
        .firstWhere((e) => e['atKey'] == 'cached:$atSign_2:$key$atSign_1');
    expect(entry['operation'], '-');
    expect(entry['opTime'], dAtWire,
        reason: 'the delete auto-notification carries dAt as :uAt: and the '
            'receiver records it as the DELETE entry\'s opTime');
  }, timeout: Timeout(Duration(seconds: 180)));

  test('autoNotify transmits the STORED timestamps: a plain update with cAt '
      'yields a cached key carrying that cAt on the receiver', () async {
    if (!bothSidesCapable) {
      markTestSkipped('an atServer in this pairing predates the 5.10.0 '
          'protocol enhancements');
      return;
    }
    var key = 'ankey-$lastValue';
    var value = 'an-value-$lastValue';

    // No explicit notify: the plain update's auto-notification must read the
    // STORED record (asserted cAt included) and transmit it.
    await sh1.writeCommand(
        'update:ttr:100000:cAt:$cAtWire:$atSign_2:$key$atSign_1 $value');
    String response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    response = await pollUntil(
        sh2,
        'llookup:all:cached:$atSign_2:$key$atSign_1',
        (r) => r.startsWith('data:'));
    final Map metaData =
        jsonDecode(response.replaceAll('data:', ''))['metaData'];
    expect(metaData['createdAt'], cAtJson,
        reason: 'the auto-notification is queued after the write, from the '
            'stored metadata — a pre-store fabricated createdAt would '
            'arrive here instead of the asserted one');
  }, timeout: Timeout(Duration(seconds: 180)));

  test('an origin absolute expiry survives the hop: eAt alongside ttl is '
      'not rederived on the receiver', () async {
    if (!bothSidesCapable) {
      markTestSkipped('an atServer in this pairing predates the 5.10.0 '
          'protocol enhancements');
      return;
    }
    var key = 'eatkey-$lastValue';
    var value = 'eat-value-$lastValue';

    // ttl accompanies eAt: a receiver that rederived would store
    // now+ttl, not the transmitted absolute instant.
    await sh1.writeCommand('notify:update:ttl:600000:ttr:-1'
        ':eAt:$eAtWire'
        ':$atSign_2:$key$atSign_1:$value');
    String response = await sh1.read();
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    String notificationId = response.replaceAll('data:', '');
    await notification.getNotifyStatus(sh1, notificationId,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 60000);

    response = await pollUntil(
        sh2,
        'llookup:all:cached:$atSign_2:$key$atSign_1',
        (r) => r.startsWith('data:'));
    final Map metaData =
        jsonDecode(response.replaceAll('data:', ''))['metaData'];
    expect(metaData['expiresAt'], eAtJson,
        reason: 'the cached copy must hold the origin\'s absolute expiry, '
            'not one rederived from now+ttl at cache time');
    expect(metaData['ttl'], 600000);
  }, timeout: Timeout(Duration(seconds: 180)));

  test('update:nc still auto-notifies: the receiver caches the key although '
      'the sender wrote no commit entry', () async {
    if (!bothSidesCapable) {
      markTestSkipped('an atServer in this pairing predates the 5.10.0 '
          'protocol enhancements');
      return;
    }
    var key = 'nckey-$lastValue';
    var value = 'nc-value-$lastValue';

    await sh1.writeCommand(
        'update:nc:ttr:100000:$atSign_2:$key$atSign_1 $value');
    String response = await sh1.read();
    expect(response.trim(), 'data:-1',
        reason: 'the no-commit write returns -1 on the sender');

    // :nc changes commit-log behaviour ONLY — the auto-notification still
    // crosses to the other atServer and caches the key there.
    response = await pollUntil(sh2, 'llookup:cached:$atSign_2:$key$atSign_1',
        (r) => r.contains('data:$value'));
    expect(response, contains('data:$value'));

    // And the sender's own commit log holds nothing for the key.
    await sh1.writeCommand('scan:cl $key');
    response = await sh1.read();
    final List entries = jsonDecode(response.replaceAll('data:', ''));
    expect(entries, isEmpty,
        reason: 'the sender wrote no commit entry for the :nc update');
  }, timeout: Timeout(Duration(seconds: 180)));
}
