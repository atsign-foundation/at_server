import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

import 'equivalence_harness.dart';

/// (grammar key, VerbSyntax regex, commands) for each ported verb.
final _cases = <String, ({String regex, List<String> commands})>{
  'llookup': (
    regex: VerbSyntax.llookup,
    commands: [
      'llookup:phone.wavi@alice',
      'llookup:public:phone@alice',
      'llookup:@bob:phone.wavi@alice',
      'llookup:meta:public:phone@alice',
      'llookup:all:@bob:phone.wavi@alice',
      'llookup:cached:public:phone@alice',
      'llookup:meta:cached:public:phone@alice',
      'llookup:metadata@alice', // key starts with "meta"
      'llookup:allkeys@alice', // key starts with "all"
      'llookup:publicish@alice', // key starts with "public"
      'llookup:shared_key.bob@alice',
      // negatives
      'llookup:@alice',
      'llookup',
      'llookup:key',
      'llookup::key@alice',
      'llookup:key@',
    ],
  ),
  'lookup': (
    regex: VerbSyntax.lookup,
    commands: [
      'lookup:phone@alice',
      'lookup:meta:phone@alice',
      'lookup:all:phone@alice',
      'lookup:bypassCache:true:phone@alice',
      'lookup:bypassCache:false:meta:phone@alice',
      'lookup:email@bob@alice', // key containing @
      'lookup:metadata@alice',
      'lookup:allthings@alice',
      // negatives
      'lookup::phone@alice',
      'lookup:phone',
      'lookup:@alice',
      'lookup:',
    ],
  ),
  'plookup': (
    regex: VerbSyntax.plookup,
    commands: [
      'plookup:phone@alice',
      'plookup:meta:phone@alice',
      'plookup:all:phone@alice',
      'plookup:bypassCache:true:phone@alice',
      'plookup:key:with:colons@alice',
      'plookup:metadata@alice',
      // negatives
      'plookup:phone',
      'plookup:@alice',
      'plookup:',
    ],
  ),
  'delete': (
    regex: VerbSyntax.delete,
    commands: [
      'delete:public:phone@alice',
      'delete:@bob:phone.wavi@alice',
      'delete:force:public:phone@alice',
      'delete:cached:public:phone@alice',
      'delete:priority:low:public:phone@alice',
      'delete:priority:high:public:phone@alice',
      'delete:dAt:2024-01-01T00:00:00Z:public:phone@alice',
      'delete:nc:public:phone@alice',
      'delete:force:nc:priority:medium:cached:@bob:phone.wavi@alice',
      'delete:privatekey:at_secret',
      'delete:phone@alice',
      'delete:phone',
      // negatives
      'delete',
      'delete:',
      'delete:priority:bogus:public:phone@alice',
    ],
  ),
  'update': (
    regex: VerbSyntax.update,
    commands: [
      'update:public:phone@alice 1234',
      'update:@bob:phone.wavi@alice myvalue',
      'update:ttl:1000:public:phone@alice val',
      'update:ttl:1000:ttb:2000:ccd:true:public:phone@alice val',
      'update:json:{"key":"value"}',
      'update:nc:public:phone@alice val',
      'update:nc:json:{"a":1}',
      'update:isEncrypted:false:sharedKeyEnc:xyz:pubKeyCS:abc:public:phone@alice hello world',
      'update:ttr:-1:public:phone@alice v',
      'update:privatekey:at_pkam_publickey mykey',
      'update:phone@alice value with spaces',
      'update:phone value-without-atsign',
      // negatives
      'update:public:phone@alice', // no value
      'update',
      'update:',
    ],
  ),
  'update:meta': (
    regex: VerbSyntax.update_meta,
    commands: [
      'update:meta:public:phone@alice:ttl:1000',
      'update:meta:@bob:phone.wavi@alice:ttl:1000:ttb:2000',
      'update:meta:phone@alice:isBinary:true',
      'update:meta:nc:public:phone@alice:ttr:-1',
      'update:meta:phone@alice:ccd:false:immutable:true',
      // negatives
      'update:meta:phone',
      'update:meta',
    ],
  ),
  'notify': (
    regex: VerbSyntax.notify,
    commands: [
      'notify:update:messageType:key:notifier:system:ttr:-1:@bob:phone.wavi@alice',
      'notify:update:ttln:5000:ttr:-1:@bob:message@alice:Hey',
      'notify:@alice:nottrkey@alice:value',
      'notify:id:abc-123:update:@bob:key@alice',
      'notify:update:priority:low:strategy:all:latestN:1:sharedKeyEnc:GxIjM8e/nsga3:pubKeyCS:5d52f6f2868:@bob:phone.wavi@alice:989745456',
      'notify:delete:messageType:text:@bob:key@alice',
      'notify:public:phone@alice',
      'notify:public:phone@alice:somevalue',
      // negatives
      'notify:phone@alice', // missing required public/@forAtSign
      'notify',
    ],
  ),
};

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
        test(_name(c), () => expectEquivalent(g, data.regex, c));
      }
    });
  });
}

String _name(String c) => c.length > 64 ? '${c.substring(0, 61)}...' : c;
