import 'dart:convert';

import 'package:at_commons/at_commons.dart' show AtConstants;
import 'package:at_demo_data/at_demo_data.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:at_functional_test/utils/auth_utils.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

/// Catalogue: features/batch/batch_verbs.feature
void main() {
  final String atSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  final String host =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  final int port =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  /// Connections opened by a test, closed in tearDown.
  final List<OutboundConnectionFactory> open = [];

  tearDown(() async {
    for (final c in open) {
      try {
        await c.close();
      } on Exception {
        // The atServer may have closed it already.
      }
    }
    open.clear();
  });

  /// A connection to [atSign]'s atServer that has authenticated with
  /// [authType].
  Future<OutboundConnectionFactory> authenticatedWith(AuthType authType) async {
    final c = await OutboundConnectionFactory()
        .initiateConnectionWithListener(atSign, host, port);
    open.add(c);
    expect((await c.authenticateConnection(authType: authType)).trim(),
        'data:success');
    return c;
  }

  /// The proof [verb] answers a fresh challenge on [c] with.
  Future<String> proofFor(String verb, OutboundConnectionFactory c) async {
    final String challenge =
        (await c.sendRequestToServer('from:$atSign')).replaceAll('data:', '');
    return verb == 'cram'
        ? AuthenticationUtils.getCRAMDigest(atSign, challenge)
        : AuthenticationUtils.generatePKAMDigest(
            pkamPrivateKeyMap[atSign]!, challenge);
  }

  /// Whether the atServer has stopped answering on [c].
  Future<bool> isClosed(OutboundConnectionFactory c) async {
    try {
      await c.sendRequestToServer('noop:0', maxWaitMilliSeconds: 5000);
      return false;
    } on Exception {
      return true;
    }
  }

  /// Checks that [c] is still authenticated with [auth]: only a cram
  /// connection may write the legacy pkam key, and a pkam connection refuses
  /// a cram.
  Future<void> expectAuthenticatedWith(
      AuthType auth, OutboundConnectionFactory c) async {
    if (auth == AuthType.cram) {
      expect(
          await c.sendRequestToServer(
              'update:${AtConstants.atPkamPublicKey} ${pkamPublicKeyMap[atSign]}'),
          'data:-1');
    } else {
      expect(await c.sendRequestToServer('cram:${await proofFor('cram', c)}'),
          startsWith('error:AT0009'));
    }
  }

  String batchOf(List<Object?> entries) => 'batch:${jsonEncode(entries)}';

  /// The entries of the batch [answer].
  List<dynamic> entriesOf(String answer) {
    expect(answer, startsWith('data:['));
    return jsonDecode(answer.substring('data:'.length));
  }

  /// The code and description of the error [answer], in either form the
  /// atServer writes one: JSON for a client that declared a version above
  /// 3.0.37, as this connection does, else `<code>-<description>`.
  (String?, String?) errorOf(String answer) {
    expect(answer, startsWith('error:'));
    final String error = answer.substring('error:'.length);
    if (error.startsWith('{')) {
      final Map<String, dynamic> json = jsonDecode(error);
      return (json['errorCode'], json['errorDescription']);
    }
    final RegExpMatch? plain =
        RegExp(r'^(AT\d{4})-(.*)$', dotAll: true).firstMatch(error);
    return (plain?.group(1), plain?.group(2));
  }

  /// The response a batch entry carries for a command that answered
  /// [answer] on its own.
  Map<String, Object?> asEntry(String answer) {
    if (answer.startsWith('data:')) {
      return {'data': answer.substring('data:'.length)};
    }
    final (String? code, String? description) = errorOf(answer);
    return {
      'error_code': code,
      'error_message': description?.split(' : ').first
    };
  }

  group('A batch carrying anything but the six is refused whole', () {
    for (final (
          AuthType auth,
          String row,
          Future<Object?> Function(OutboundConnectionFactory) entry
        ) in [
      (AuthType.pkam, 'monitor', (_) async => {'id': 2, 'command': 'monitor'}),
      (
        AuthType.pkam,
        'cram:<digest>',
        (c) async => {'id': 2, 'command': 'cram:${await proofFor('cram', c)}'}
      ),
      (
        AuthType.cram,
        'pkam:<digest>',
        (c) async => {'id': 2, 'command': 'pkam:${await proofFor('pkam', c)}'}
      ),
      (
        AuthType.pkam,
        'from:@alice',
        (_) async => {'id': 2, 'command': 'from:$atSign'}
      ),
      (
        AuthType.pkam,
        'notify:list',
        (_) async => {'id': 2, 'command': 'notify:list'}
      ),
      (
        AuthType.pkam,
        'notify:all:@bob:phone.wavi@alice:v',
        (_) async => {'id': 2, 'command': 'notify:all:@bob:phone.wavi$atSign:v'}
      ),
      (
        AuthType.pkam,
        'batch:[{"id":1,"command":"noop:0"}]',
        (_) async => {'id': 2, 'command': 'batch:[{"id":1,"command":"noop:0"}]'}
      ),
      (
        AuthType.pkam,
        'stream:init@carol namespace:wavi s1 f.txt 12',
        (_) async =>
            {'id': 2, 'command': 'stream:init@carol namespace:wavi s1 f.txt 12'}
      ),
      (
        AuthType.pkam,
        '{"id":2}, an entry with no command',
        (_) async => {'id': 2}
      ),
    ]) {
      test('${auth.name}, $row', () async {
        final OutboundConnectionFactory c = await authenticatedWith(auth);
        final String key = 'batch-${Uuid().v4()}';
        final Object? second = await entry(c);

        final String answer = await c.sendRequestToServer(batchOf([
          {'id': 1, 'command': 'update:public:$key$atSign 1'},
          second
        ]));

        expect(answer, startsWith('error:'),
            reason: 'the whole batch is refused, so an error answers it');
        expect(errorOf(answer), (
          'AT0003',
          'Invalid syntax : a batch may carry only lookup, llookup, plookup,'
              ' notify, update and delete; entry 2 is not one'
        ));
        expect(
            errorOf(await c.sendRequestToServer('llookup:public:$key$atSign'))
                .$1,
            'AT0015',
            reason: 'public:<key>@alice still does not exist');
        expect(await isClosed(c), isFalse);
        await expectAuthenticatedWith(auth, c);
      });
    }
  });

  group('A batch carrying one of the six runs it', () {
    for (final (String row, String Function(String key) command, bool reads)
        in [
      ('lookup:<key>@alice', (key) => 'lookup:$key$atSign', true),
      (
        'llookup:public:<key>@alice',
        (key) => 'llookup:public:$key$atSign',
        true
      ),
      ('plookup:<key>@alice', (key) => 'plookup:$key$atSign', true),
      (
        'notify:update:@alice:<key>.wavi@alice:v',
        (key) => 'notify:update:$atSign:$key.wavi$atSign:v',
        false
      ),
      (
        'update:public:<key>@alice 2',
        (key) => 'update:public:$key$atSign 2',
        false
      ),
      (
        'update:meta:public:<key>@alice:ttr:-1',
        (key) => 'update:meta:public:$key$atSign:ttr:-1',
        false
      ),
      (
        'delete:public:<key>@alice',
        (key) => 'delete:public:$key$atSign',
        false
      ),
    ]) {
      test(row, () async {
        final OutboundConnectionFactory c =
            await authenticatedWith(AuthType.pkam);
        final String key = 'batch-${Uuid().v4()}';
        expect(await c.sendRequestToServer('update:public:$key$atSign 1'),
            startsWith('data:'));
        final String? alone =
            reads ? await c.sendRequestToServer(command(key)) : null;

        final List<dynamic> entries =
            entriesOf(await c.sendRequestToServer(batchOf([
          {'id': 1, 'command': command(key)}
        ])));

        expect(entries, hasLength(1));
        expect(entries.single['id'], 1);
        if (alone != null) {
          expect(entries.single['response'], asEntry(alone),
              reason: 'what ${command(key)} answers on its own: $alone');
        } else {
          expect(entries.single['response'], containsPair('data', isNotNull));
          expect(entries.single['response'], isNot(contains('error_code')));
        }
      });
    }
  });

  test('A batch runs its commands in order', () async {
    final OutboundConnectionFactory c = await authenticatedWith(AuthType.pkam);
    final String key = 'batch-${Uuid().v4()}';

    final List<dynamic> entries =
        entriesOf(await c.sendRequestToServer(batchOf([
      {'id': 1, 'command': 'update:public:$key$atSign 1'},
      {'id': 2, 'command': 'llookup:public:$key$atSign'},
      {'id': 3, 'command': 'delete:public:$key$atSign'},
      {'id': 4, 'command': 'llookup:public:$key$atSign'},
    ])));

    expect(entries.map((dynamic e) => e['id']), [1, 2, 3, 4]);
    expect(entries[1]['response']['data'], '1');
    expect(entries[3]['response']['error_code'], 'AT0015');
  });
}
