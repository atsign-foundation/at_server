import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/keys_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_list_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/scan_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart' show AuthType;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../test_utils.dart';

/// The atServer's own `local:` records: no client verb names one, and scan
/// lists none.
void main() {
  const String record = 'local:chat.rule.gate@alice';

  Gatekeeper gate() => AtSecondaryServerImpl.getInstance().gatekeeper;

  late String stored;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    await gate().setRule('chat', GateMode.closed, admit: bob);
    stored = (await keyValueStore.get(record))!.data!;
  });

  tearDown(() async => await verbTestsTearDown());

  void asCram() => inboundConnection.metadata
    ..isAuthenticated = true
    ..authType = AuthType.cram
    ..enrollmentId = null;

  Future<void> asRoot() async {
    final String enrollmentId = Uuid().v4();
    inboundConnection.metadata
      ..isAuthenticated = true
      ..authType = AuthType.apkam
      ..enrollmentId = enrollmentId;
    await keyValueStore.put(
        '$enrollmentId.new.enrollments.__manage$alice',
        AtData()
          ..data = jsonEncode({
            'sessionId': '123',
            'appName': 'gate',
            'deviceName': 'test',
            'namespaces': {'*': 'rw', '__manage': 'rw'},
            'apkamPublicKey': 'testPublicKeyValue',
            'requestType': 'newEnrollment',
            'approval': {'state': 'approved'}
          }));
  }

  Future<String?> codeOf(AbstractVerbHandler verb, String command) async {
    Exception? refused;
    try {
      await verb.processInternal(command, inboundConnection);
    } on Exception catch (e) {
      refused = e;
    }
    expect(refused, isNotNull, reason: '"$command" was not refused');
    return GlobalExceptionHandler.getInstance().getErrorCode(refused!);
  }

  Future<String?> answer(AbstractVerbHandler verb, String command) async =>
      (await verb.processInternal(command, inboundConnection)).data;

  LookupVerbHandler lookup() => LookupVerbHandler(
      keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
      accessLog: atAccessLog);

  ScanVerbHandler scan() =>
      ScanVerbHandler(keyValueStore, mockOutboundClientManager, cacheManager);

  for (final (String name, Future<void> Function() connect) in [
    ('CRAM', () async => asCram()),
    ('a root enrollment', asRoot),
  ]) {
    group('Given the gate record $record, over $name', () {
      setUp(() async => await connect());

      for (final String command in [
        'llookup:$record',
        'llookup:all:$record',
        'lookup:$record',
        'lookup:all:$record',
      ]) {
        test('when "$command" names it, then it is refused', () async {
          expect(
              await codeOf(
                  command.startsWith('llookup')
                      ? LocalLookupVerbHandler(keyValueStore, enMgr)
                      : lookup(),
                  command),
              'AT0009');
        });
      }

      test('when update:json names it, then it is refused and unchanged',
          () async {
        final String json = jsonEncode({
          'atKey': record,
          'value': jsonEncode({'mode': 'open'}),
          'metadata': Metadata().toJson(),
        });
        expect(
            await codeOf(
                UpdateVerbHandler(keyValueStore, statsNotificationService,
                    notificationManager, alice),
                'update:json:$json'),
            'AT0009');
        expect((await keyValueStore.get(record))!.data, stored);
      });

      test('when it scans, then the record is not listed', () async {
        for (final String command in ['scan', 'scan:showhidden:true']) {
          final List<dynamic> listed =
              jsonDecode((await answer(scan(), command))!);
          expect(listed, isNot(contains(record)), reason: command);
        }
      });

      test('when a key with no local: prefix is looked up, then it answers',
          () async {
        await keyValueStore.put('status.chat$alice', AtData()..data = 'v');
        expect(
            await answer(LocalLookupVerbHandler(keyValueStore, enMgr),
                'llookup:status.chat$alice'),
            'v');
      });
    });
  }

  group('Given the gate record $record, over a root enrollment', () {
    setUp(() async => await asRoot());

    test('when keys:get names it, then it is refused', () async {
      expect(
          await codeOf(KeysVerbHandler(keyValueStore, enMgr, alice),
              'keys:get:keyName:$record'),
          'AT0009');
    });

    test(
        'when keys:get names a local: key that does not exist, then it is'
        ' refused as one that does', () async {
      expect(
          await codeOf(KeysVerbHandler(keyValueStore, enMgr, alice),
              'keys:get:keyName:local:photos.rule.gate$alice'),
          'AT0009');
    });

    test('when the client notifies a key named local:, then it is refused',
        () async {
      expect(
          await codeOf(NotifyVerbHandler(keyValueStore, notificationManager),
              'notify:@bob:$record'),
          'AT0009');
    });

    test(
        'when the client sends a text notification that begins "local:", then'
        ' it is sent', () async {
      expect(
          await answer(NotifyVerbHandler(keyValueStore, notificationManager),
              'notify:messageType:text:@bob:local: see you there'),
          isNotNull);
    });
  });

  group('Given a received notification whose key has a part named local', () {
    setUp(() async {
      await gate().setDefault(GateDefault.ungated);
      await NotifyVerbHandler(keyValueStore, notificationManager)
          .processInternal(
              'notify:id:n1:@alice:x:local:y.photos@bob',
              DummyInboundConnection()
                ..metadata.isPolAuthenticated = true
                ..metadata.fromAtSign = bob);
    });

    for (final (String name, Future<void> Function() connect) in [
      ('CRAM', () async => asCram()),
      ('a root enrollment', asRoot),
    ]) {
      test('when notify:list is sent over $name, then it lists it', () async {
        await connect();
        final String? listed = await answer(
            NotifyListVerbHandler(keyValueStore, notificationManager),
            'notify:list');
        expect([for (final n in jsonDecode(listed!)) n['id']], ['n1']);
      });
    }
  });
}
