import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^scan$|scan(:cl(?<commitLog>))?(:showhidden:(?<showhidden>true|false))?`
/// `(:(?<forAtSign>@[^:@\s]+))?(:page:(?<page>\d+))?( (?<regex>\S+))?$`
final scanGrammar = VerbGrammar('scan', [
  Flag('commitLog', ':cl'),
  Field('showhidden', leader: ':showhidden:', rule: boolRule, optional: true),
  Field('forAtSign', leader: ':', rule: atSignRequiredPrefix, optional: true),
  Field('page', leader: ':page:', rule: uintRule, optional: true),
  Field('regex', leader: ' ', rule: tokenNoSpace, optional: true),
]);

/// `^otp:(?<operation>get|put)(:(?<otp>(?<=put:)\w{6,}))?`
/// `(:(?:ttl:(?<ttl>\d+)))?$`
final otpGrammar = VerbGrammar('otp:', [
  Field('operation', rule: enumRule(['get', 'put'])),
  GatedField('otp',
      leader: ':',
      rule: wordMin6,
      gate: (out) => (out['operation'] ?? '').toLowerCase() == 'put'),
  Field('ttl', leader: ':ttl:', rule: uintRule, optional: true),
]);

/// `^stats(?<statId>:((?!0)\d+)?(,(\d+))*)?(:(?<regex>(?<=:3:|:15:).+))?$`
final statsGrammar = VerbGrammar('stats', [
  Field('statId', rule: statIdRule, optional: true),
  GatedField('regex',
      leader: ':',
      rule: restRule,
      gate: (out) => out['statId'] == ':3' || out['statId'] == ':15'),
]);

/// `^enroll:(?<operation>request|approve|deny|revoke|listns|infons|list|fetch`
/// `|unrevoke|delete|update)(:(?<force>force))?(:(?<listNamespace>[^:{\n]+))?`
/// `(?::)?((?<enrollParams>.+)|...)?$`
final enrollGrammar = VerbGrammar('enroll:', [
  Field('operation',
      rule: enumRule([
        'request',
        'approve',
        'deny',
        'revoke',
        'listns',
        'infons',
        'list',
        'fetch',
        'unrevoke',
        'delete',
        'update',
      ])),
  Field('force', leader: ':', rule: literal('force'), optional: true),
  Field('listNamespace',
      leader: ':', rule: notColonBraceNewline, optional: true),
  OptLit(':'),
  Field('enrollParams', rule: restRule, optional: true),
]);

/// `^config:` then one of:
///   `block:(?<operation>show)\s?$`
///   `block:(?<operation>add|remove):(?<atSign>@x( @y)*)$`
///   `(?<setOperation>set|reset|print):(?<configNew>.+)$`
final configGrammar = VerbGrammar('config:', [
  Alt([
    [Lit('block:'), Field('operation', rule: literal('show')), OptWs()],
    [
      Lit('block:'),
      Field('operation', rule: enumRule(['add', 'remove'])),
      Lit(':'),
      Field('atSign', rule: configAtSignListRule),
    ],
    [
      Field('setOperation', rule: enumRule(['set', 'reset', 'print'])),
      Lit(':'),
      Field('configNew', rule: restRule),
    ],
  ]),
]);

/// `^keys:((?<operation>put|get|delete):?)(?:(?<visibility>public|private|self):?)?`
/// `(?:namespace:(?<namespace>[a-zA-Z0-9_]+):?)?(?:appName:(?<appName>...):?)?`
/// `(?:deviceName:(?<deviceName>...):?)?(?:keyType:(?<keyType>[a-zA-Z0-9_-]+):?)?`
/// `(?:encryptionKeyName:(?<encryptionKeyName>...):?)?`
/// `(?:keyName:(?<keyName>\S+) ?)?(?<keyValue>.*)?$`
final keysGrammar = VerbGrammar('keys:', [
  Field('operation',
      rule: enumRule(['put', 'get', 'delete']),
      trailer: ':',
      optionalTrailer: true),
  Field('visibility',
      rule: enumRule(['public', 'private', 'self']),
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('namespace',
      leader: 'namespace:',
      rule: alnumUnderscore,
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('appName',
      leader: 'appName:',
      rule: alnumUnderscore,
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('deviceName',
      leader: 'deviceName:',
      rule: alnumUnderscore,
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('keyType',
      leader: 'keyType:',
      rule: alnumDashUnderscore,
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('encryptionKeyName',
      leader: 'encryptionKeyName:',
      rule: alnumDashUnderscore,
      trailer: ':',
      optionalTrailer: true,
      optional: true),
  Field('keyName',
      leader: 'keyName:',
      rule: tokenNoSpace,
      trailer: ' ',
      optionalTrailer: true,
      optional: true),
  // `(?<keyValue>.*)?` yields null (not '') when empty — the group's `?` wins —
  // so this is an optional min-1 rest, not restStar.
  Field('keyValue', rule: restRule, optional: true),
]);

/// `^notify:all:((?<operation>update|delete):)?(messageType:((?<messageType>key|text):))?`
/// `(?:ttl:(?<ttl>\d+):)?(?:ttb:(?<ttb>\d+):)?(?:ttr:(?<ttr>-?\d+):)?`
/// `(?:ccd:(?<ccd>true|false+):)?(?<forAtSign>(([^:\s])+)?(,([^:\s]+))*)`
/// `(:(?<atKey>[^@:\s]+))(@(?<atSign>[^@:\s]+))?(:(?<value>.+))?$`
final notifyAllGrammar = VerbGrammar('notify:all:', [
  Field('operation',
      rule: enumRule(['update', 'delete']), trailer: ':', optional: true),
  Field('messageType',
      leader: 'messageType:',
      rule: enumRule(['key', 'text']),
      trailer: ':',
      optional: true),
  Field('ttl', leader: 'ttl:', rule: uintRule, trailer: ':', optional: true),
  Field('ttb', leader: 'ttb:', rule: uintRule, trailer: ':', optional: true),
  Field('ttr', leader: 'ttr:', rule: intRule, trailer: ':', optional: true),
  Field('ccd', leader: 'ccd:', rule: ccdPlusRule, trailer: ':', optional: true),
  Field('forAtSign', rule: forAtSignListRule),
  Lit(':'),
  Field('atKey', rule: notAtColonSpace),
  Field('atSign', leader: '@', rule: notAtColonSpace, optional: true),
  Field('value', leader: ':', rule: restRule, optional: true),
]);
