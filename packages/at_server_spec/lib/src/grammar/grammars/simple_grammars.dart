import '../scanner.dart';
import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^pol$`
final polGrammar = VerbGrammar('pol', []);

/// `^noop:(?<delayMillis>\d+)$`
final noopGrammar = VerbGrammar('noop:', [
  Field('delayMillis', rule: uintRule),
]);

/// `^cram:(?<digest>.+$)`
final cramGrammar = VerbGrammar('cram:', [
  Field('digest', rule: restRule),
]);

/// `^batch:(?<json>.+)$`
final batchGrammar = VerbGrammar('batch:', [
  Field('json', rule: restRule),
]);

/// `^info(:(brief|mtls|mtlsbrief))?$` — no captured groups.
final infoGrammar = VerbGrammar('info', [
  OptAlt([':brief', ':mtls', ':mtlsbrief']),
]);

/// `^sync:(?<from_commit_seq>[0-9]+|-1)(:(?<regex>.+))?$` (deprecated sync).
final syncGrammar = VerbGrammar('sync:', [
  Field('from_commit_seq', rule: commitSeqRule),
  Field('regex', leader: ':', rule: restRule, optional: true),
]);

/// `^sync:from:(?<from_commit_seq>[0-9]+|-1)(:limit:(?<limit>\d+))?`
/// `(:skipDeletesUntil:(?<skipDeletesUntil>\d+))?(:(?<regex>.+))?$`
final syncFromGrammar = VerbGrammar('sync:from:', [
  Field('from_commit_seq', rule: commitSeqRule),
  Field('limit', leader: ':limit:', rule: uintRule, optional: true),
  Field('skipDeletesUntil',
      leader: ':skipDeletesUntil:', rule: uintRule, optional: true),
  Field('regex', leader: ':', rule: restRule, optional: true),
]);

/// `^monitor(:(?<strict>strict))?(:(?<selfNotifications>selfNotifications))?`
/// `(:(?<multiplexed>multiplexed))?(:(?<epochMillis>\d+))?( (?<regex>.+))?$`
final monitorGrammar = VerbGrammar('monitor', [
  Field('strict', leader: ':', rule: literal('strict'), optional: true),
  Field('selfNotifications',
      leader: ':', rule: literal('selfNotifications'), optional: true),
  Field('multiplexed', leader: ':', rule: literal('multiplexed'), optional: true),
  Field('epochMillis', leader: ':', rule: uintRule, optional: true),
  Field('regex', leader: ' ', rule: restRule, optional: true),
]);

/// `^notify:status:(?<notificationId>\S+)$`
final notifyStatusGrammar = VerbGrammar('notify:status:', [
  Field('notificationId', rule: tokenNoSpace),
]);

/// `^notify:fetch:(?<notificationId>\S+)$`
final notifyFetchGrammar = VerbGrammar('notify:fetch:', [
  Field('notificationId', rule: tokenNoSpace),
]);

/// `notify:remove:(?<id>[\w\d\-\_]+)` — unanchored (no `^`/`$`).
final notifyRemoveGrammar = VerbGrammar('notify:remove:', [
  Field('id', rule: idRule),
], anchored: false);

/// `^notify:list(:(?<fromDate>DATE))?(:(?<toDate>DATE))?(:(?<regex>[^:]+))?`
/// (no trailing `$` — matches a prefix).
final notifyListGrammar = VerbGrammar('notify:list', [
  Field('fromDate', leader: ':', rule: notifyDateRule, optional: true),
  Field('toDate', leader: ':', rule: notifyDateRule, optional: true),
  Field('regex', leader: ':', rule: charClass(notColon), optional: true),
], anchored: false);
