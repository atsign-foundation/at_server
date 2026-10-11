import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:mutex/mutex.dart';

/// How an atSign's gate treats a namespace that has no rule: as today, or
/// closed.
enum GateDefault { ungated, closed }

/// Whether a namespace with a rule lets in an atSign it has not admitted.
enum GateMode { open, closed }

/// The gate's answer for one exchange with another atSign.
enum GateVerdict { admitted, quarantined, notAccepted }

/// A quarantine setting of an open namespace, named as the gate verb names it.
enum GateSetting { limit, window, size, maxQuarantined, maxQuarantinedBytes }

/// The operator's quarantine defaults and bounds, and the atSign-wide caps.
class GateLimits {
  final Map<GateSetting, int> defaults;

  /// The most each setting may be set to; a setting absent has no ceiling.
  final Map<GateSetting, int> ceilings;

  /// The least each setting may be set to.
  final Map<GateSetting, int> floors;

  /// How many open namespaces one atSign may have.
  final int maxOpenNamespaces;

  /// How many namespaces one atSign may have with a rule or recorded
  /// admissions.
  final int maxNamespaces;

  /// How many atSigns one namespace may admit.
  final int maxAdmitted;

  /// How many atSigns one namespace may deny.
  final int maxDenied;

  /// How many atSigns the atSign-wide admitted set may hold.
  final int maxAdmittedEverywhere;

  const GateLimits({
    this.defaults = const {
      GateSetting.limit: 10,
      GateSetting.window: 24 * 60 * 60,
      GateSetting.size: 15360,
      GateSetting.maxQuarantined: 100,
      GateSetting.maxQuarantinedBytes: 1024 * 1024,
    },
    this.ceilings = const {
      GateSetting.limit: 100,
      GateSetting.size: 65536,
      GateSetting.maxQuarantined: 1000,
      GateSetting.maxQuarantinedBytes: 16 * 1024 * 1024,
    },
    this.floors = const {
      GateSetting.limit: 1,
      GateSetting.window: 60 * 60,
      GateSetting.size: 1,
      GateSetting.maxQuarantined: 1,
      GateSetting.maxQuarantinedBytes: 1,
    },
    this.maxOpenNamespaces = 50,
    this.maxNamespaces = 1000,
    this.maxAdmitted = 10000,
    this.maxDenied = 10000,
    this.maxAdmittedEverywhere = 10000,
  });
}

/// What the gate holds for one namespace: its rule's mode, the atSigns
/// admitted and denied in it, and the settings its holders have set.
///
/// A closed namespace admits only its admitted set, and keeps its denied set
/// and settings for when it is opened again.
class GateRule {
  /// The rule's mode, or null when the namespace has no rule and holds only
  /// the admissions recorded there.
  GateMode? mode;
  final Set<Atsign> admitted;
  final Set<Atsign> denied;
  final Map<GateSetting, int> settings;

  GateRule(this.mode,
      {Set<Atsign>? admitted,
      Set<Atsign>? denied,
      Map<GateSetting, int>? settings})
      : admitted = admitted ?? <Atsign>{},
        denied = denied ?? <Atsign>{},
        settings = settings ?? <GateSetting, int>{};

  /// A rule equal to this one that changes independently of it.
  GateRule copy() => GateRule(mode,
      admitted: {...admitted}, denied: {...denied}, settings: {...settings});
}

/// An atSign's gate: its default, a rule per namespace, and an atSign-wide
/// admitted set, deciding every exchange with another atSign.
///
/// Every change runs under one mutex and is written to the [GateStore], when
/// there is one, before it takes effect; a check only reads, and takes none.
class Gatekeeper {
  /// The namespace a change to the atSign-wide admitted set names.
  static const String everyNamespace = '*';

  final GateLimits limits;
  final GateStore? _store;
  GateDefault _default;
  final Map<String, GateRule> _rules = {};
  final Set<Atsign> _admittedEverywhere = {};
  final Mutex _writes = Mutex();

  Gatekeeper(
      {GateDefault defaultMode = GateDefault.ungated,
      this.limits = const GateLimits(),
      GateStore? store})
      : _default = defaultMode,
        _store = store;

  /// The gate [store] last wrote, with [startingDefault] as its default when
  /// none has been written.
  static Future<Gatekeeper> load(GateStore store,
      {GateDefault startingDefault = GateDefault.ungated,
      GateLimits limits = const GateLimits()}) async {
    final GateRecords records = await store.load();
    final Gatekeeper gate = Gatekeeper(
        defaultMode: records.defaultMode ?? startingDefault,
        limits: limits,
        store: store);
    gate._rules.addAll(records.rules);
    gate._admittedEverywhere.addAll(records.admittedEverywhere);
    return gate;
  }

  GateDefault get defaultMode => _default;

  /// The atSigns admitted in every open namespace.
  Set<Atsign> get admittedEverywhere => Set.unmodifiable(_admittedEverywhere);

  /// What the gate holds for exactly [namespace]: its rule, or the admissions
  /// recorded there, or null.
  GateRule? ruleFor(String namespace) => _rules[namespace];

  /// The namespaces with a rule or recorded admissions, sorted.
  List<String> get namespaces => _rules.keys.toList()..sort();

  /// The value of [setting] in force for [rule]: its own, or the operator's
  /// default.
  int settingOf(GateRule rule, GateSetting setting) =>
      rule.settings[setting] ?? limits.defaults[setting]!;

  /// The verdict for an exchange from [other] about the key named [keyName],
  /// given without its owner. [onShortList] says whether an exchange with no
  /// namespace is one that admission anywhere lets through.
  GateVerdict inbound(Atsign other, String keyName,
      {bool onShortList = false}) {
    final int dot = keyName.indexOf('.');
    if (dot < 0) {
      if (_default == GateDefault.ungated) {
        return GateVerdict.admitted;
      }
      return onShortList && isAdmittedSomewhere(other)
          ? GateVerdict.admitted
          : GateVerdict.notAccepted;
    }
    return check(keyName.substring(dot + 1), other);
  }

  /// The verdict an exchange from [other] in [namespace] gets now.
  ///
  /// The most specific rule covering [namespace] decides. Where none does, the
  /// default decides, and under `closed` admits exactly the atSigns recorded
  /// on the most specific covering namespace that has admissions recorded.
  GateVerdict check(String namespace, Atsign other) {
    final GateRule? rule =
        _mostSpecific(namespace, (rule) => rule.mode != null);
    if (rule == null) {
      if (_default == GateDefault.ungated) {
        return GateVerdict.admitted;
      }
      final GateRule? recorded = _mostSpecific(namespace, (_) => true);
      return recorded != null && recorded.admitted.contains(other)
          ? GateVerdict.admitted
          : GateVerdict.notAccepted;
    }
    switch (rule.mode!) {
      case GateMode.closed:
        return rule.admitted.contains(other)
            ? GateVerdict.admitted
            : GateVerdict.notAccepted;
      case GateMode.open:
        if (rule.denied.contains(other)) {
          return GateVerdict.notAccepted;
        }
        return rule.admitted.contains(other) ||
                _admittedEverywhere.contains(other)
            ? GateVerdict.admitted
            : GateVerdict.quarantined;
    }
  }

  /// The most specific rule covering the key named [keyName]: the rule for
  /// the longest namespace that ends the key's name, or null.
  GateRule? ruleCovering(String keyName) {
    final int dot = keyName.indexOf('.');
    return dot < 0
        ? null
        : _mostSpecific(keyName.substring(dot + 1), (rule) => rule.mode != null);
  }

  /// The entry [test] accepts for [namespace] or the nearest namespace above
  /// it, by P1's suffix match.
  GateRule? _mostSpecific(String namespace, bool Function(GateRule) test) {
    String? candidate = namespace;
    while (candidate != null) {
      final GateRule? rule = _rules[candidate];
      if (rule != null && test(rule)) {
        return rule;
      }
      final int dot = candidate.indexOf('.');
      candidate = dot < 0 ? null : candidate.substring(dot + 1);
    }
    return null;
  }

  /// Whether [other] is in some namespace's admitted set or the atSign-wide
  /// one.
  bool isAdmittedSomewhere(Atsign other) =>
      _admittedEverywhere.contains(other) ||
      _rules.values.any((rule) => rule.admitted.contains(other));

  /// [namespace]'s rule and sets, or the atSign-wide admitted set when
  /// [namespace] is [everyNamespace], as `gate:show` answers them.
  Map<String, Object?> show(String namespace) {
    if (namespace == everyNamespace) {
      return {'namespace': namespace, 'admitted': _sorted(_admittedEverywhere)};
    }
    final GateRule? rule = _rules[namespace];
    final GateMode? mode = rule?.mode;
    if (mode == null) {
      return {
        'namespace': namespace,
        'mode': 'none',
        'default': _default.name,
        'admitted': _sorted(rule?.admitted ?? const {}),
      };
    }
    return {
      'namespace': namespace,
      'mode': mode.name,
      'settings': {
        for (final GateSetting setting in GateSetting.values)
          setting.name: settingOf(rule!, setting)
      },
      'admitted': _sorted(rule!.admitted),
      'denied': _sorted(rule.denied),
      if (mode == GateMode.open) 'quarantined': <Map<String, Object?>>[],
    };
  }

  /// Switches the default for namespaces with no rule.
  Future<void> setDefault(GateDefault mode) => _writes.protect(() async {
        await _store?.putDefault(mode);
        _default = mode;
      });

  /// Gives [namespace] the rule [mode], keeping its sets and settings, setting
  /// [setting] to [value] when given, or back to the operator's default when
  /// [value] is null, and admitting [admit] when given. A rule set where
  /// admissions are recorded starts from them.
  ///
  /// Throws [IllegalArgumentException] when [value] is outside the operator's
  /// bounds, or when the change would pass one of the atSign's caps; nothing
  /// changes then.
  Future<void> setRule(String namespace, GateMode mode,
          {GateSetting? setting, int? value, Atsign? admit}) =>
      _writes.protect(() async {
        if (setting != null && value != null) {
          _checkBounds(setting, value);
        }
        final GateRule? existing = _rules[namespace];
        if (mode == GateMode.open &&
            existing?.mode != GateMode.open &&
            _openCount() >= limits.maxOpenNamespaces) {
          throw IllegalArgumentException(
              'This atSign already has ${limits.maxOpenNamespaces} open'
              ' namespaces, the most it may have');
        }
        final GateRule rule = existing?.copy() ?? _newEntry(namespace);
        rule.mode = mode;
        if (setting != null) {
          if (value == null) {
            rule.settings.remove(setting);
          } else {
            rule.settings[setting] = value;
          }
        }
        if (admit != null) {
          _addAdmitted(namespace, rule, admit);
        }
        await _putRule(namespace, rule);
      });

  /// Admits [other] in [namespace], or in every open namespace when
  /// [namespace] is [everyNamespace]. Where [namespace] has no rule, the
  /// admission is recorded there without creating one.
  ///
  /// Throws [IllegalArgumentException] when the admission would pass one of
  /// the atSign's caps.
  Future<void> admit(String namespace, Atsign other) =>
      _writes.protect(() async {
        if (namespace == everyNamespace) {
          if (!_admittedEverywhere.contains(other) &&
              _admittedEverywhere.length >= limits.maxAdmittedEverywhere) {
            throw IllegalArgumentException(
                'The atSign-wide admitted set already holds'
                ' ${limits.maxAdmittedEverywhere} atSigns, the most it may');
          }
          await _putAdmittedEverywhere({..._admittedEverywhere, other});
          return;
        }
        final GateRule rule =
            _rules[namespace]?.copy() ?? _newEntry(namespace);
        _addAdmitted(namespace, rule, other);
        await _putRule(namespace, rule);
      });

  /// Denies [other] in the open [namespace].
  ///
  /// Throws [IllegalArgumentException] when [namespace] is not open, which
  /// [everyNamespace] never is, or when its denied set is full.
  Future<void> deny(String namespace, Atsign other) =>
      _writes.protect(() async {
        final GateRule? existing = _rules[namespace];
        if (existing?.mode != GateMode.open) {
          throw IllegalArgumentException(
              'Only an open namespace denies; $namespace is not open');
        }
        final GateRule rule = existing!.copy();
        if (!rule.denied.contains(other) &&
            rule.denied.length >= limits.maxDenied) {
          throw IllegalArgumentException('$namespace already denies'
              ' ${limits.maxDenied} atSigns, the most it may');
        }
        rule.denied.add(other);
        rule.admitted.remove(other);
        await _putRule(namespace, rule);
      });

  /// Takes [other] out of [namespace]'s admitted and denied sets, or out of
  /// the atSign-wide admitted set when [namespace] is [everyNamespace]. A
  /// namespace with no rule whose last recorded admission goes is forgotten.
  Future<void> remove(String namespace, Atsign other) =>
      _writes.protect(() async {
        if (namespace == everyNamespace) {
          await _putAdmittedEverywhere(
              {..._admittedEverywhere}..remove(other));
          return;
        }
        final GateRule? existing = _rules[namespace];
        if (existing == null) {
          return;
        }
        final GateRule rule = existing.copy();
        rule.admitted.remove(other);
        rule.denied.remove(other);
        if (rule.mode == null && rule.admitted.isEmpty) {
          await _store?.deleteRule(namespace);
          _rules.remove(namespace);
          return;
        }
        await _putRule(namespace, rule);
      });

  /// A new entry for [namespace], which has none.
  ///
  /// Throws [IllegalArgumentException] when the atSign already has its cap of
  /// namespaces with a rule or recorded admissions.
  GateRule _newEntry(String namespace) {
    if (_rules.length >= limits.maxNamespaces) {
      throw IllegalArgumentException(
          'This atSign already has ${limits.maxNamespaces} namespaces with a'
          ' rule or recorded admissions, the most it may have');
    }
    return GateRule(null);
  }

  void _addAdmitted(String namespace, GateRule rule, Atsign other) {
    if (!rule.admitted.contains(other) &&
        rule.admitted.length >= limits.maxAdmitted) {
      throw IllegalArgumentException('$namespace already admits'
          ' ${limits.maxAdmitted} atSigns, the most it may');
    }
    rule.admitted.add(other);
    rule.denied.remove(other);
  }

  Future<void> _putRule(String namespace, GateRule rule) async {
    await _store?.putRule(namespace, rule);
    _rules[namespace] = rule;
  }

  Future<void> _putAdmittedEverywhere(Set<Atsign> atSigns) async {
    await _store?.putAdmittedEverywhere(atSigns);
    _admittedEverywhere
      ..clear()
      ..addAll(atSigns);
  }

  void _checkBounds(GateSetting setting, int value) {
    final int? ceiling = limits.ceilings[setting];
    final int floor = limits.floors[setting] ?? 0;
    if (ceiling != null && value > ceiling) {
      throw IllegalArgumentException(
          '${setting.name} may be at most $ceiling on this atServer');
    }
    if (value < floor) {
      throw IllegalArgumentException(
          '${setting.name} must be at least $floor on this atServer');
    }
  }

  int _openCount() =>
      _rules.values.where((rule) => rule.mode == GateMode.open).length;

  static List<String> _sorted(Set<Atsign> atSigns) =>
      atSigns.map((a) => '$a').toList()..sort();
}
