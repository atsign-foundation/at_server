import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';

/// An atSign's gate as it was last written: its default, if one was, its rules
/// and its atSign-wide admitted set.
class GateRecords {
  final GateDefault? defaultMode;
  final Map<String, GateRule> rules;
  final Set<Atsign> admittedEverywhere;

  GateRecords(this.defaultMode, this.rules, this.admittedEverywhere);
}

/// Keeps an atSign's gate in its keystore as `local:` records, which never
/// enter the commit log, so they never sync.
class GateStore {
  static const String _ruleSuffix = '.rule.gate';

  /// The mode recorded for a namespace that has no rule, only admissions.
  static const String _noRule = 'none';

  final AtKeyValueStore<String, AtData, AtMetaData?> keyStore;
  final Atsign atSign;

  GateStore(this.keyStore, this.atSign);

  String _ruleKey(String namespace) => 'local:$namespace$_ruleSuffix$atSign';
  String get _admittedKey => 'local:admitted.gate$atSign';
  String get _defaultKey => 'local:default.gate$atSign';

  Future<void> putDefault(GateDefault mode) =>
      _put(_defaultKey, {'default': mode.name});

  Future<void> putRule(String namespace, GateRule rule) =>
      _put(_ruleKey(namespace), {
        'mode': rule.mode?.name ?? _noRule,
        'admitted': [for (final Atsign a in rule.admitted) '$a'],
        'denied': [for (final Atsign a in rule.denied) '$a'],
        'settings': {
          for (final MapEntry<GateSetting, int> s in rule.settings.entries)
            s.key.name: s.value
        },
      });

  Future<void> deleteRule(String namespace) =>
      keyStore.remove(_ruleKey(namespace));

  Future<void> putAdmittedEverywhere(Set<Atsign> atSigns) =>
      _put(_admittedKey, {
        'admitted': [for (final Atsign a in atSigns) '$a']
      });

  /// Reads back every record this store has written.
  Future<GateRecords> load() async {
    final Map<String, dynamic>? defaultRecord = await _get(_defaultKey);
    final GateDefault? defaultMode = defaultRecord == null
        ? null
        : GateDefault.values.byName(defaultRecord['default'] as String);

    final Map<String, dynamic>? admittedRecord = await _get(_admittedKey);
    final Set<Atsign> admittedEverywhere =
        _atSigns(admittedRecord?['admitted']);

    final Map<String, GateRule> rules = {};
    final String prefix = 'local:';
    final String suffix = '$_ruleSuffix$atSign';
    await for (final String key in await keyStore
        .scanKeys(KeyPattern(sharedBy: '$atSign', namespace: 'gate'))) {
      if (!key.startsWith(prefix) || !key.endsWith(suffix)) {
        continue;
      }
      final String namespace =
          key.substring(prefix.length, key.length - suffix.length);
      final Map<String, dynamic> record = (await _get(key))!;
      final String mode = record['mode'] as String;
      rules[namespace] = GateRule(
        mode == _noRule ? null : GateMode.values.byName(mode),
        admitted: _atSigns(record['admitted']),
        denied: _atSigns(record['denied']),
        settings: {
          for (final MapEntry<String, dynamic> s
              in (record['settings'] as Map<String, dynamic>).entries)
            GateSetting.values.byName(s.key): s.value as int
        },
      );
    }
    return GateRecords(defaultMode, rules, admittedEverywhere);
  }

  Future<void> _put(String key, Map<String, Object?> record) =>
      keyStore.put(key, AtData()..data = jsonEncode(record));

  Future<Map<String, dynamic>?> _get(String key) async {
    if (!await keyStore.exists(key)) {
      return null;
    }
    final AtData? data = await keyStore.get(key);
    return data?.data == null ? null : jsonDecode(data!.data!);
  }

  static Set<Atsign> _atSigns(Object? list) =>
      {for (final Object? a in (list as List<dynamic>? ?? const [])) '$a'.toAtsign()};
}
