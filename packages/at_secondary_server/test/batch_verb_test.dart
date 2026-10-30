import 'dart:convert';

import 'package:at_commons/at_commons.dart' show Response;
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enrollment_manager.dart';
import 'package:at_secondary/src/verb/handler/batch_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// Catalogue: features/batch/batch_verbs.feature
void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async {
    await setUpAtSignBound();
    await enMgr.serialiseMutation(() => enMgr.mintPrimary('a pkam key'));
  });
  tearDown(() async => await verbTestsTearDown());

  /// @alice's client, authenticated with [auth]; a pkam stands on the
  /// primary enrollment, as a legacy pkam does.
  Connection client(AuthType auth) => Connection(InboundConnectionMetadata()
    ..isAuthenticated = true
    ..authType = auth
    ..enrollmentId =
        auth == AuthType.cram ? null : EnrollmentManager.primaryEnrollmentId);

  String batchOf(List<Object?> entries) => 'batch:${jsonEncode(entries)}';

  /// The entries of the batch answer last written to [connection].
  List<dynamic> entriesOf(Connection connection) {
    final String answer = connection.writes.last;
    expect(answer, startsWith('data:['));
    return jsonDecode(answer.substring('data:'.length).split('\n').first);
  }

  group('A batch carrying anything but the six is refused whole', () {
    final Object update = {'id': 1, 'command': 'update:public:phone$alice 1'};
    for (final (AuthType auth, String row, List<Object?> entries) in [
      (
        AuthType.pkamLegacy,
        'monitor',
        [
          {'id': 2, 'command': 'monitor'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'cram:<digest>',
        [
          {'id': 2, 'command': 'cram:abc'}
        ]
      ),
      (
        AuthType.cram,
        'pkam:<digest>',
        [
          {'id': 2, 'command': 'pkam:abc'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'from:@alice',
        [
          {'id': 2, 'command': 'from:$alice'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'notify:list',
        [
          {'id': 2, 'command': 'notify:list'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'notify:all:@bob:phone.wavi@alice:v',
        [
          {'id': 2, 'command': 'notify:all:@bob:phone.wavi$alice:v'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'batch:[{"id":1,"command":"noop:0"}]',
        [
          {'id': 2, 'command': 'batch:[{"id":1,"command":"noop:0"}]'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        'stream:init@carol namespace:wavi s1 f.txt 12',
        [
          {'id': 2, 'command': 'stream:init@carol namespace:wavi s1 f.txt 12'}
        ]
      ),
      (
        AuthType.pkamLegacy,
        '{"id":2}, an entry with no command',
        [
          {'id': 2},
          {'id': 2, 'command': 7},
          {'id': 2, 'commmand': 'update:public:phone$alice 2'},
          {'id': '2', 'command': 'update:public:phone$alice 2'},
          5,
          'update:public:phone$alice 2',
          null,
          [
            {'id': 2},
            {'id': 3, 'command': 'monitor'}
          ],
        ]
      ),
    ]) {
      test('${auth == AuthType.cram ? 'cram' : 'pkam'}, $row', () async {
        for (final Object? entry in entries) {
          final List<Object?> after = entry is List ? entry : [entry];
          final Connection connection = client(auth);
          final List<Object?> before = await footprint();

          await send(batchOf([update, ...after]), connection);

          expect(
              connection.writes,
              [
                'error:AT0003-Invalid syntax : a batch may carry only lookup,'
                    ' llookup, plookup, notify, update and delete; entry 2 is'
                    ' not one\n$alice@'
              ],
              reason: 'entries after the first: ${jsonEncode(after)}');
          expect(await footprint(), before,
              reason: 'public:phone$alice still does not exist');
          expect(connection.closeCount, 0);
          expect(connection.metadata.isAuthenticated, isTrue);
          expect(connection.metadata.authType, auth);
        }
      });
    }
  });

  /// The response a batch entry carries for a command that answered
  /// [answer] on its own.
  Map<String, Object?> asEntry(String answer) {
    final String line = answer.split('\n').first;
    if (line.startsWith('data:')) {
      return {'data': line.substring('data:'.length)};
    }
    final RegExpMatch? error =
        RegExp(r'^error:(AT\d{4})-(.*?)(?: : .*)?$').firstMatch(line);
    expect(error, isNotNull, reason: 'an answer of a known form: $line');
    return {'error_code': error!.group(1), 'error_message': error.group(2)};
  }

  group('A batch carrying one of the six runs it', () {
    for (final (String command, bool reads) in [
      ('lookup:phone$alice', true),
      ('llookup:public:phone$alice', true),
      ('plookup:phone$alice', true),
      ('notify:update:$alice:phone.wavi$alice:v', false),
      ('update:public:phone$alice 2', false),
      ('update:meta:public:phone$alice:ttr:-1', false),
      ('delete:public:phone$alice', false),
    ]) {
      test(command, () async {
        final Connection connection = client(AuthType.pkamLegacy);
        await send('update:public:phone$alice 1', connection);
        String? alone;
        if (reads) {
          await send(command, connection);
          alone = connection.writes.last;
        }

        await send(
            batchOf([
              {'id': 1, 'command': command}
            ]),
            connection);

        final List<dynamic> entries = entriesOf(connection);
        expect(entries, hasLength(1));
        expect(entries.single['id'], 1);
        if (alone != null) {
          expect(entries.single['response'], asEntry(alone),
              reason: 'what $command answers on its own: $alone');
        } else {
          expect(entries.single['response'], containsPair('data', isNotNull));
          expect(entries.single['response'], isNot(contains('error_code')));
        }
      });
    }
  });

  test('A batch runs its commands in order', () async {
    final Connection connection = client(AuthType.pkamLegacy);

    await send(
        batchOf([
          {'id': 1, 'command': 'update:public:phone$alice 1'},
          {'id': 2, 'command': 'llookup:public:phone$alice'},
          {'id': 3, 'command': 'delete:public:phone$alice'},
          {'id': 4, 'command': 'llookup:public:phone$alice'},
        ]),
        connection);

    final List<dynamic> entries = entriesOf(connection);
    expect(entries.map((dynamic e) => e['id']), [1, 2, 3, 4]);
    expect(entries[1]['response']['data'], '1');
    expect(entries[3]['response']['error_code'], 'AT0015');
  });

  test(
      'A command in a batch that throws an Error is answered AT0010, and the'
      ' others still run', () async {
    final Connection connection = client(AuthType.pkamLegacy);
    const String throwing = 'update:public:throws@alice 1';
    final BatchVerbHandler batch =
        BatchVerbHandler(keyValueStore, _Throwing(verbs, throwing));

    await batch.process(
        batchOf([
          {'id': 1, 'command': throwing},
          {'id': 2, 'command': 'update:public:phone$alice 1'},
        ]),
        connection);

    final List<dynamic> entries = entriesOf(connection);
    expect(entries[0], {
      'id': 1,
      'response': {
        'error_code': 'AT0010',
        'error_message': 'Internal server error'
      }
    });
    expect(entries[1]['response']['data'], isNotNull);
    expect((await keyValueStore.get('public:phone$alice'))?.data, '1');
  });

  test('when a batch is not a list, then it is refused with AT0003', () async {
    final Connection connection = client(AuthType.cram);

    await send(
        'batch:{"id":1,"command":"update:public:phone$alice 1"}', connection);

    expect(connection.writes.single, startsWith('error:AT0003'));
    expect(await keyValueStore.exists('public:phone$alice'), isFalse);
  });
}

/// The atServer's verb handlers, but with [_command] run by a handler that
/// throws a [StateError].
class _Throwing implements VerbHandlerManager {
  _Throwing(this._verbs, this._command);

  final VerbHandlerManager _verbs;
  final String _command;

  @override
  VerbHandler? getVerbHandler(String command) =>
      command == _command ? _ThrowingUpdate() : _verbs.getVerbHandler(command);
}

class _ThrowingUpdate extends UpdateVerbHandler {
  _ThrowingUpdate()
      : super(keyValueStore, statsNotificationService, notificationManager,
            alice);

  @override
  Future<Response> processInternal(
          String command, InboundConnection atConnection) async =>
      throw StateError('a handler that throws');
}
