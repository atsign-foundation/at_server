import '../metadata_fragment.dart';
import '../segment.dart';
import '../value_rules.dart';
import '../verb_grammar.dart';

/// `^notify(:id:(?<id>[\w\d\-\_]+))?(:(?<operation>update|delete))?`
/// `(:messageType:(?<messageType>key|text))?(:priority:(?<priority>low|medium|high))?`
/// `(:strategy:(?<strategy>all|latest))?(:latestN:(?<latestN>\d+))?`
/// `(:notifier:(?<notifier>[^\s:]+))?(:ttln:(?<ttln>\d+))?<metadataFragment>`
/// `:((?<publicScope>public)|(@(?<forAtSign>[^:@\s]+)))`
/// `:(?<atKey>[^:@]((?!:{2})[^@])+)(@(?<atSign>[^:@\s]+))?(:(?<value>.+))?$`
final notifyGrammar = VerbGrammar('notify', [
  Field('id', leader: ':id:', rule: idRule, optional: true),
  Field('operation', leader: ':', rule: enumRule(['update', 'delete']), optional: true),
  Field('messageType',
      leader: ':messageType:', rule: enumRule(['key', 'text']), optional: true),
  Field('priority',
      leader: ':priority:',
      rule: enumRule(['low', 'medium', 'high']),
      optional: true),
  Field('strategy',
      leader: ':strategy:', rule: enumRule(['all', 'latest']), optional: true),
  Field('latestN', leader: ':latestN:', rule: uintRule, optional: true),
  Field('notifier', leader: ':notifier:', rule: notifierRule, optional: true),
  Field('ttln', leader: ':ttln:', rule: uintRule, optional: true),
  ...metadataFragment(),
  PublicOrForAtSign('publicScope', 'forAtSign', required: true),
  Field('atKey', leader: ':', rule: keyFirstNoColonAt),
  Field('atSign', leader: '@', rule: tokenNoColonAtSpace, optional: true),
  Field('value', leader: ':', rule: restRule, optional: true),
]);
