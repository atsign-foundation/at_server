import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

import 'equivalence_harness.dart';

final _cases = <String, ({String regex, List<String> commands})>{
  'scan': (regex: VerbSyntax.scan, commands: [
    'scan',
    'scan:cl',
    'scan:showhidden:true',
    'scan:showhidden:false:@bob',
    'scan:@bob',
    'scan:page:2',
    'scan:cl:showhidden:true:@bob:page:3 .*wavi',
    'scan mobile-123',
    'scan .*\\.wavi',
    // negatives
    'scanx',
    'scan:showhidden:maybe',
    'scan:page:x',
  ]),
  'otp': (regex: VerbSyntax.otp, commands: [
    'otp:get',
    'otp:put',
    'otp:put:abcdef',
    'otp:put:abcdef123',
    'otp:get:ttl:5000',
    'otp:put:abcdef:ttl:5000',
    // negatives
    'otp:get:abcdef', // lookbehind: otp only after put:
    'otp:put:abc', // < 6 chars
    'otp:bogus',
    'otp:',
  ]),
  'stats': (regex: VerbSyntax.stats, commands: [
    'stats',
    'stats:3',
    'stats:15',
    'stats:3,15',
    'stats:1,2,3',
    'stats:3:myfilter',
    'stats:15:myfilter',
    'stats:11:filter', // lookbehind: filter only after :3:/:15:
    'stats:0', // leading zero
    'stats:',
  ]),
  'enroll': (regex: VerbSyntax.enroll, commands: [
    'enroll:request:appName:wavi:deviceName:pixel',
    'enroll:approve:enrollmentId:abc-123',
    'enroll:list',
    'enroll:listns',
    'enroll:list:wavi',
    'enroll:deny:enrollmentId:abc',
    'enroll:revoke:force:enrollmentId:abc',
    // negatives
    'enroll:bogus',
    'enroll:',
  ]),
  'config': (regex: VerbSyntax.config, commands: [
    'config:block:show',
    'config:block:add:@bob',
    'config:block:add:@bob @charlie',
    'config:block:remove:@bob',
    'config:set:commitLogCompactionFrequencyMins=4',
    'config:reset:inboundMaxLimit',
    'config:print:inboundMaxLimit',
    // negatives
    'config:block:show:@bob',
    'config:block:add',
    'config:bogus',
  ]),
  'keys': (regex: VerbSyntax.keys, commands: [
    'keys:get',
    'keys:put:public:namespace:__manage:keyName:foo bar',
    'keys:get:self',
    'keys:delete:private:namespace:ns1:appName:wavi:deviceName:pixel',
    'keys:put:keyType:aes256:encryptionKeyName:my_key:keyName:k1 value1',
    'keys:get:public',
    // negatives
    'keys:bogus',
    'keys:',
  ]),
  'notify:all': (regex: VerbSyntax.notifyAll, commands: [
    'notify:all:@bob:phone.wavi@alice',
    'notify:all:update:@bob:phone@alice',
    'notify:all:update:messageType:key:@bob,@charlie:phone@alice',
    'notify:all:ttl:1000:ttb:2000:ttr:-1:ccd:true:@bob:phone@alice',
    'notify:all:@bob:phone@alice:somevalue',
    // negatives
    'notify:all:',
    'notify:all:@bob',
  ]),
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
