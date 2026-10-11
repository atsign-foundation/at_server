import 'package:at_commons/at_commons.dart';
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
  });
}

/// A namespace's rule: its mode, the atSigns admitted and denied in it, and
/// the settings its holders have set.
///
/// A closed namespace holds only an admitted set; its settings are kept for
/// when it is opened again.
class GateRule {
  GateMode mode;
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
}

/// An atSign's gate: its default, a rule per namespace, and an atSign-wide
/// admitted set, deciding every exchange with another atSign.
///
/// Every change runs under one mutex; a check only reads, and takes none.
class Gatekeeper {
  /// The namespace a change to the atSign-wide admitted set names.
  static const String everyNamespace = '*';

  final GateLimits limits;
  GateDefault _default;
  final Map<String, GateRule> _rules = {};
  final Set<Atsign> _admittedEverywhere = {};
  final Mutex _writes = Mutex();

  Gatekeeper(
      {GateDefault defaultMode = GateDefault.ungated,
      this.limits = const GateLimits()})
      : _default = defaultMode;

  GateDefault get defaultMode => _default;

  /// The atSigns admitted in every open namespace.
  Set<Atsign> get admittedEverywhere => Set.unmodifiable(_admittedEverywhere);

  /// The rule set for exactly [namespace], or null.
  GateRule? ruleFor(String namespace) => _rules[namespace];

  /// The value of [setting] in force for [rule]: its own, or the operator's
  /// default.
  int settingOf(GateRule rule, GateSetting setting) =>
      rule.settings[setting] ?? limits.defaults[setting]!;

  /// The verdict for an exchange from [other] about the key named [keyName],
  /// given without its owner. [onShortList] says whether an exchange with no
  /// namespace is one that admission anywhere lets through.
  GateVerdict inbound(Atsign other, String keyName,
      {bool onShortList = false}) {
    if (!keyName.contains('.')) {
      if (_default == GateDefault.ungated) {
        return GateVerdict.admitted;
      }
      return onShortList && isAdmittedSomewhere(other)
          ? GateVerdict.admitted
          : GateVerdict.notAccepted;
    }
    final GateRule? rule = ruleCovering(keyName);
    if (rule == null) {
      return _default == GateDefault.ungated
          ? GateVerdict.admitted
          : GateVerdict.notAccepted;
    }
    switch (rule.mode) {
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
    int dot = keyName.indexOf('.');
    while (dot >= 0) {
      final GateRule? rule = _rules[keyName.substring(dot + 1)];
      if (rule != null) {
        return rule;
      }
      dot = keyName.indexOf('.', dot + 1);
    }
    return null;
  }

  /// Whether [other] is in some namespace's admitted set or the atSign-wide
  /// one.
  bool isAdmittedSomewhere(Atsign other) =>
      _admittedEverywhere.contains(other) ||
      _rules.values.any((rule) => rule.admitted.contains(other));

  /// [namespace]'s rule and sets, as `gate:show` answers them.
  Map<String, Object?> show(String namespace) {
    final GateRule? rule = _rules[namespace];
    if (rule == null) {
      return {'namespace': namespace, 'mode': 'none', 'default': _default.name};
    }
    final List<String> admitted = _sorted(rule.admitted);
    if (rule.mode == GateMode.closed) {
      return {'namespace': namespace, 'mode': 'closed', 'admitted': admitted};
    }
    return {
      'namespace': namespace,
      'mode': 'open',
      'settings': {
        for (final GateSetting setting in GateSetting.values)
          setting.name: settingOf(rule, setting)
      },
      'admitted': admitted,
      'denied': _sorted(rule.denied),
      'quarantined': <Map<String, Object?>>[],
    };
  }

  /// Switches the default for namespaces with no rule.
  Future<void> setDefault(GateDefault mode) =>
      _writes.protect(() async => _default = mode);

  /// Gives [namespace] the rule [mode], keeping its sets and settings, setting
  /// [setting] to [value] when given, and admitting [admit] when given.
  /// Closing a namespace drops its denied set.
  ///
  /// Throws [IllegalArgumentException] when [value] is outside the operator's
  /// bounds, or when opening [namespace] would pass the atSign's cap on open
  /// namespaces; nothing changes then.
  Future<void> setRule(String namespace, GateMode mode,
          {GateSetting? setting, int? value, Atsign? admit}) =>
      _writes.protect(() async {
        if (setting != null) {
          _checkBounds(setting, value!);
        }
        final GateRule? existing = _rules[namespace];
        if (mode == GateMode.open &&
            existing?.mode != GateMode.open &&
            _openCount() >= limits.maxOpenNamespaces) {
          throw IllegalArgumentException(
              'This atSign already has ${limits.maxOpenNamespaces} open'
              ' namespaces, the most it may have');
        }
        final GateRule rule =
            _rules.putIfAbsent(namespace, () => GateRule(mode));
        rule.mode = mode;
        if (mode == GateMode.closed) {
          rule.denied.clear();
        }
        if (setting != null) {
          rule.settings[setting] = value!;
        }
        if (admit != null) {
          rule.admitted.add(admit);
          rule.denied.remove(admit);
        }
      });

  /// Admits [other] in [namespace], or in every open namespace when
  /// [namespace] is [everyNamespace].
  ///
  /// Throws [IllegalArgumentException] when [namespace] has no rule.
  Future<void> admit(String namespace, Atsign other) =>
      _writes.protect(() async {
        if (namespace == everyNamespace) {
          _admittedEverywhere.add(other);
          return;
        }
        final GateRule rule = _requireRule(namespace);
        rule.admitted.add(other);
        rule.denied.remove(other);
      });

  /// Denies [other] in the open [namespace].
  ///
  /// Throws [IllegalArgumentException] when [namespace] has no rule, which
  /// [everyNamespace] never has, or is closed.
  Future<void> deny(String namespace, Atsign other) =>
      _writes.protect(() async {
        final GateRule rule = _requireRule(namespace);
        if (rule.mode != GateMode.open) {
          throw IllegalArgumentException(
              'Only an open namespace denies; $namespace is closed');
        }
        rule.denied.add(other);
        rule.admitted.remove(other);
      });

  /// Takes [other] out of [namespace]'s admitted and denied sets, or out of
  /// the atSign-wide admitted set when [namespace] is [everyNamespace].
  ///
  /// Throws [IllegalArgumentException] when [namespace] has no rule.
  Future<void> remove(String namespace, Atsign other) =>
      _writes.protect(() async {
        if (namespace == everyNamespace) {
          _admittedEverywhere.remove(other);
          return;
        }
        final GateRule rule = _requireRule(namespace);
        rule.admitted.remove(other);
        rule.denied.remove(other);
      });

  GateRule _requireRule(String namespace) {
    final GateRule? rule = _rules[namespace];
    if (rule == null) {
      throw IllegalArgumentException('$namespace has no rule');
    }
    return rule;
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
