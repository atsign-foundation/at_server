import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

import 'equivalence_harness.dart';

final _cases = <String, ({String regex, List<String> commands})>{
  'pol': (regex: VerbSyntax.pol, commands: [
    'pol',
    'pol:x',
    'poll',
    'po',
    '',
  ]),
  'noop': (regex: VerbSyntax.noOp, commands: [
    'noop:0',
    'noop:5000',
    'noop:',
    'noop:abc',
    'noop',
  ]),
  'cram': (regex: VerbSyntax.cram, commands: [
    'cram:digest123',
    'cram:a:b:c',
    'cram:',
    'cram',
  ]),
  'batch': (regex: VerbSyntax.batch, commands: [
    'batch:{"x":1}',
    'batch:anything here',
    'batch:',
    'batch',
  ]),
  'info': (regex: VerbSyntax.info, commands: [
    'info',
    'info:brief',
    'info:mtls',
    'info:mtlsbrief',
    'info:x',
    'info:',
  ]),
  'sync': (regex: _syncRegex, commands: [
    'sync:0',
    'sync:-1',
    'sync:5:myregex',
    'sync:123',
    'sync:from:0', // sync grammar must reject (syncFrom's job)
    'sync:',
    'sync:abc',
    'sync',
  ]),
  'sync:from': (regex: VerbSyntax.syncFrom, commands: [
    'sync:from:0',
    'sync:from:-1',
    'sync:from:5:limit:10',
    'sync:from:5:limit:10:skipDeletesUntil:20:myregex',
    'sync:from:5:someregex',
    'sync:from:',
    'sync:from:abc',
  ]),
  'monitor': (regex: VerbSyntax.monitor, commands: [
    'monitor',
    'monitor:strict',
    'monitor:strict:selfNotifications:multiplexed:12345 myregex',
    'monitor:12345',
    'monitor .*',
    'monitor:strict .*',
    'monitor:bogus',
  ]),
  'notify:status': (regex: VerbSyntax.notifyStatus, commands: [
    'notify:status:abc-123',
    'notify:status:',
    'notify:status:a b',
  ]),
  'notify:fetch': (regex: VerbSyntax.notifyFetch, commands: [
    'notify:fetch:abc-123',
    'notify:fetch:',
  ]),
  'notify:remove': (regex: VerbSyntax.notifyRemove, commands: [
    'notify:remove:abc-123',
    'notify:remove:abc_1',
    'notify:remove:',
  ]),
  'notify:list': (regex: VerbSyntax.notifyList, commands: [
    'notify:list',
    'notify:list:2024-01-01',
    'notify:list:2024-01-01:2024-02-01',
    'notify:list:2024-01-01:2024-02-01:myregex',
    'notify:list:myregex',
  ]),
};

// VerbSyntax.sync is deprecated; capture it once behind an ignore.
// ignore: deprecated_member_use
const _syncRegex = VerbSyntax.sync;

void main() {
  _cases.forEach((verb, data) {
    group('$verb: structural', () {
      test('field names match regex named groups', () {
        expect(verbGrammars[verb]!.fieldNames,
            equals(namedGroupsOf(data.regex)));
      });
    });
    group('$verb: equivalence', () {
      final g = verbGrammars[verb]!;
      for (final c in data.commands) {
        test(c.isEmpty ? '(empty)' : c,
            () => expectEquivalent(g, data.regex, c));
      }
    });
  });
}
