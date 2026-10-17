import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:test/test.dart';

import 'atsign_bound_harness.dart';
import 'test_utils.dart';

/// A command naming @over in each group of a handler's grammar that names an
/// atSign, keyed by the handler's type and the group.
final Map<String, String> commands = {
  'FromVerbHandler.atSign': 'from:$over',
  'ToVerbHandler.atSign': 'to:$over',
  'UpdateVerbHandler.forAtSign': 'update:$over:phone.wavi@alice v',
  'UpdateVerbHandler.atSign': 'update:phone.wavi$over v',
  'UpdateMetaVerbHandler.forAtSign':
      'update:meta:$over:phone.wavi@alice:ttl:60000',
  'UpdateMetaVerbHandler.atSign': 'update:meta:phone.wavi$over:ttl:60000',
  'LocalLookupVerbHandler.forAtSign': 'llookup:$over:phone.wavi@alice',
  'LocalLookupVerbHandler.atSign': 'llookup:phone.wavi$over',
  'ProxyLookupVerbHandler.atSign': 'plookup:phone.wavi$over',
  'LookupVerbHandler.atSign': 'lookup:phone.wavi$over',
  'ScanVerbHandler.forAtSign': 'scan:$over',
  'DeleteVerbHandler.forAtSign': 'delete:$over:phone.wavi@alice',
  'DeleteVerbHandler.atSign': 'delete:phone.wavi$over',
  'ConfigVerbHandler.atSign': 'config:block:add:@carol $over',
  'StreamVerbHandler.receiver':
      'stream:init$over namespace:wavi startByte:0 s1 f.txt 10',
  'NotifyVerbHandler.forAtSign':
      'notify:update:messageType:key:$over:phone.wavi@alice:v',
  'NotifyVerbHandler.atSign':
      'notify:update:messageType:key:@bob:phone.wavi$over:v',
  'NotifyAllVerbHandler.forAtSign': 'notify:all:@bob,$over:phone.wavi@alice:v',
  'NotifyAllVerbHandler.atSign': 'notify:all:@bob:phone.wavi$over:v',
};

/// An update:json document naming @over as its [field].
String updateJson(String field) => 'update:json:{"atKey":"phone.wavi",'
    '"sharedBy":"${field == 'sharedBy' ? over : '@alice'}",'
    '"sharedWith":"${field == 'sharedWith' ? over : '@bob'}","value":"v",'
    '"metadata":{"isPublic":false,"isBinary":false,"isEncrypted":false}}';

/// Whether a grammar group's [name] says it holds an atSign.
bool namesAnAtSign(String name) =>
    name.toLowerCase().contains('atsign') ||
    const {'receiver', 'sharedBy', 'sharedWith', 'recipient', 'owner'}
        .contains(name);

void main() {
  setUpAll(() async => await verbTestsSetUpAll());
  setUp(() async => await setUpAtSignBound());
  tearDown(() async => await verbTestsTearDown());

  group('Given every verb handler this atServer runs', () {
    test(
        'when its grammar is read, '
        'then every group that names an atSign has a command in this table',
        () {
      final groups = {
        for (final handler
            in verbs.verbHandlers.whereType<AbstractVerbHandler>())
          for (final group in RegExp(r'\(\?<(\w+)>')
              .allMatches(handler.getVerb().syntax())
              .map((m) => m.group(1)!))
            if (namesAnAtSign(group)) '${handler.runtimeType}.$group'
      };
      expect(groups, commands.keys.toSet());
    });

    for (final MapEntry(key: group, value: command) in commands.entries) {
      test(
          'when $group names an atSign of 56 characters, '
          'then the command is refused with AT0003 before anything is done',
          () async {
        final bool declaresItself = command.startsWith(RegExp('(from|to):'));
        final connection = declaresItself ? unauthenticated() : aliceClient();
        final before = await footprint();
        await send(command, connection);
        expect(connection.writes,
            [declaresItself ? tooLongUnauthenticated : tooLongForAlice]);
        expect(await footprint(), before);
        expectNothingLookedUp();
      });
    }

    for (final field in ['sharedBy', 'sharedWith']) {
      test(
          'when update:json\'s $field names an atSign of 56 characters, '
          'then the command is refused with AT0003 before anything is done',
          () async {
        final connection = aliceClient();
        final before = await footprint();
        await send(updateJson(field), connection);
        expect(connection.writes, [tooLongForAlice]);
        expect(await footprint(), before);
        expectNothingLookedUp();
      });
    }
  });
}
