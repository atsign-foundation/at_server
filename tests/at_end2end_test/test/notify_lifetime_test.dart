import 'dart:convert';

import 'package:test/test.dart';
// ignore: depend_on_referenced_packages
import 'package:uuid/uuid.dart';

import 'e2e_test_utils.dart' as e2e;
import 'notify_verb_test.dart' as notification;

/// Do `eAtn` and `eph` cross from one atServer to another?
///
/// @first notifies @second. @first's atServer asks @second's for its
/// features before forwarding either field, so @second receiving the
/// client's exact expiry shows that check ran over the wire.
void main() {
  late String atSign_1;
  late e2e.SimpleOutboundConnection sh1;

  late String atSign_2;
  late e2e.SimpleOutboundConnection sh2;

  setUpAll(() async {
    List<String> atSigns = e2e.knownAtSigns();
    atSign_1 = atSigns[0];
    sh1 = await e2e.getSocketHandler(atSign_1);
    atSign_2 = atSigns[1];
    sh2 = await e2e.getSocketHandler(atSign_2);
  });

  tearDownAll(() {
    sh1.close();
    sh2.close();
  });

  setUp(() async {
    sh1.clear();
    sh2.clear();
  });

  /// The feature names [sh]'s atServer lists in its `info`.
  Future<Set> features(e2e.SimpleOutboundConnection sh) async {
    await sh.writeCommand('info');
    final info = jsonDecode((await sh.read()).replaceFirst('data:', ''));
    final List listed = info['features'] ?? [];
    return listed.map((f) => f['name']).toSet();
  }

  /// Whether both atServers list [feature]; prints why a test skips if not.
  Future<bool> bothList(String feature) async {
    for (final sh in [sh1, sh2]) {
      if (!(await features(sh)).contains(feature)) {
        print('An atServer does not list $feature. Skipping.');
        return false;
      }
    }
    return true;
  }

  /// Sends [command] from @first and returns @second's listing of the
  /// notification for [key], once it is delivered.
  Future<Map> sendAndList(String command, String key) async {
    await sh1.writeCommand(command);
    final id = (await sh1.read()).replaceFirst('data:', '').trim();
    final status = await notification.getNotifyStatus(sh1, id,
        returnWhenStatusIn: ['delivered'], timeOutMillis: 15000);
    expect(status, contains('data:delivered'));
    final notificationKey = '$atSign_2:$key$atSign_1';
    final response = await notification.retryCommandUntilMatchOrTimeout(
        sh2, 'notify:list:$key', '"key":"$notificationKey"', 15000);
    final List entries = jsonDecode(response.replaceFirst('data:', ''));
    return entries.singleWhere((n) => n['key'] == notificationKey);
  }

  test('a recipient\'s atServer is given the expiry the client set', () async {
    if (!await bothList('notify.eAtn')) return;
    final key = 'eatn-${Uuid().v4()}.e2e';
    final expiry = DateTime.now().toUtc().add(const Duration(minutes: 3));
    final eAtn = '${expiry.toIso8601String().split('.').first}.000Z';
    final listed =
        await sendAndList('notify:eAtn:$eAtn:$atSign_2:$key$atSign_1:v', key);
    expect(
        DateTime.parse(listed['metadata']['expiresAt']), DateTime.parse(eAtn),
        reason: 'the sending atServer forwarded eAtn, not the remaining ttln');
  });

  test('an ephemeral notification reaches the recipient, living two minutes',
      () async {
    if (!await bothList('notify.eph')) return;
    final key = 'eph-${Uuid().v4()}.e2e';
    final sentAt = DateTime.now().toUtc();
    final listed = await sendAndList(
        'notify:ttln:600000:eph:$atSign_2:$key$atSign_1:v', key);
    expect(listed['value'], 'v');
    expect(
        DateTime.parse(listed['metadata']['expiresAt'])
            .isBefore(sentAt.add(const Duration(minutes: 2, seconds: 5))),
        isTrue,
        reason: 'eph is clamped to two minutes, though ttln asked for ten');
  });
}
