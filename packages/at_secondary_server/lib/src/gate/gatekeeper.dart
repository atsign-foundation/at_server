import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/gate/gate_store.dart';
import 'package:at_secondary/src/gate/quarantine.dart';
import 'package:clock/clock.dart';
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

  /// How many bytes of quarantined notifications the atSign may accept across
  /// its namespaces, each in its own window.
  final int maxQuarantinedBytesEverywhere;

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
    this.maxQuarantinedBytesEverywhere = 64 * 1024 * 1024,
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
  final Map<String, Map<Atsign, QuarantineEntry>> _quarantine = {};
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
    gate._quarantine.addAll(records.quarantines);
    return gate;
  }

  GateDefault get defaultMode => _default;

  /// The atSigns admitted in every open namespace and wherever the closed
  /// default decides.
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
    return dot < 0
        ? namespaceLess(other, onShortList: onShortList)
        : check(keyName.substring(dot + 1), other);
  }

  /// The verdict for an exchange from [other] that belongs to no namespace.
  /// [onShortList] says whether it is one that admission anywhere lets
  /// through.
  GateVerdict namespaceLess(Atsign other, {required bool onShortList}) {
    if (_default == GateDefault.ungated) {
      return GateVerdict.admitted;
    }
    return onShortList && isAdmittedSomewhere(other)
        ? GateVerdict.admitted
        : GateVerdict.notAccepted;
  }

  /// Decides an exchange from [other] about the key named [keyName] as
  /// [inbound] does, and counts it when [other] is quarantined. [bytes] is the
  /// size of a notification, null for a lookup.
  ///
  /// Throws [QuarantineSizeException] when the notification is over the
  /// namespace's size cap, and [QuarantineLimitException] when the exchange
  /// would pass the atSign's count in the window or a bound on the quarantine;
  /// nothing is counted then.
  Future<GateVerdict> count(Atsign other, String keyName,
          {bool onShortList = false, int? bytes}) =>
      _writes.protect(() async {
        final GateVerdict verdict =
            inbound(other, keyName, onShortList: onShortList);
        if (verdict != GateVerdict.quarantined) {
          return verdict;
        }
        final String namespace =
            _ruleCovering(keyName.substring(keyName.indexOf('.') + 1))!;
        final GateRule rule = _rules[namespace]!;
        if (bytes != null && bytes > settingOf(rule, GateSetting.size)) {
          throw QuarantineSizeException(
              'The notification is larger than this atServer quarantines');
        }
        final DateTime now = DateTime.fromMillisecondsSinceEpoch(
            clock.now().millisecondsSinceEpoch,
            isUtc: true);
        final Map<Atsign, QuarantineEntry> entries =
            _quarantinedAt(namespace, now);
        final QuarantineEntry? entry = entries[other];
        final bool full = entry == null
            ? entries.length >= settingOf(rule, GateSetting.maxQuarantined)
            : entry.counted.length >= settingOf(rule, GateSetting.limit);
        final int added = bytes ?? 0;
        if (full ||
            _bytes(entries) + added >
                settingOf(rule, GateSetting.maxQuarantinedBytes) ||
            _bytesEverywhere(now, namespace, entries) + added >
                limits.maxQuarantinedBytesEverywhere) {
          throw QuarantineLimitException(
              "This atServer's quarantine has no room for the exchange");
        }
        entries[other] = (entry ?? QuarantineEntry(now))
            .plus(CountedExchange(now, added));
        await _putQuarantine(namespace, entries);
        return verdict;
      });

  /// The atSigns quarantined in [namespace] now, each with the exchanges
  /// counted in its window.
  Map<Atsign, QuarantineEntry> quarantinedIn(String namespace) =>
      Map.unmodifiable(_quarantinedAt(namespace, clock.now()));

  /// [namespace]'s quarantined atSigns as of [now]: each with only the
  /// exchanges in the window, and without those that have none left.
  Map<Atsign, QuarantineEntry> _quarantinedAt(String namespace, DateTime now) {
    final GateRule? rule = _rules[namespace];
    if (rule?.mode != GateMode.open) {
      return {};
    }
    final DateTime start =
        now.subtract(Duration(seconds: settingOf(rule!, GateSetting.window)));
    return {
      for (final MapEntry<Atsign, QuarantineEntry> e
          in (_quarantine[namespace] ?? const {}).entries)
        if (e.value.since(start) case final QuarantineEntry kept) e.key: kept
    };
  }

  static int _bytes(Map<Atsign, QuarantineEntry> entries) =>
      entries.values.fold(0, (sum, entry) => sum + entry.bytes);

  /// The quarantined bytes accepted in every namespace's window, with
  /// [entries] standing for [namespace]'s.
  int _bytesEverywhere(DateTime now, String namespace,
          Map<Atsign, QuarantineEntry> entries) =>
      _quarantine.keys
          .where((other) => other != namespace)
          .fold(_bytes(entries),
              (sum, other) => sum + _bytes(_quarantinedAt(other, now)));

  /// Throws [NotAcceptedException] when [verdict] refuses the exchange.
  static void refuseIfNotAccepted(GateVerdict verdict) {
    if (verdict == GateVerdict.notAccepted) {
      throw NotAcceptedException('This atServer does not accept the exchange');
    }
  }

  /// The standing [other] has in [namespace] now: the verdict an exchange
  /// from it there gets.
  ///
  /// The most specific rule covering [namespace] decides. Where none does, the
  /// default decides, and under `closed` admits the atSigns recorded on any
  /// namespace covering [namespace] and the atSign-wide admitted set.
  GateVerdict check(String namespace, Atsign other) {
    final String? ruled = _ruleCovering(namespace);
    if (ruled == null) {
      if (_default == GateDefault.ungated ||
          _admittedEverywhere.contains(other) ||
          _covering(namespace).any((n) => _rules[n]!.admitted.contains(other))) {
        return GateVerdict.admitted;
      }
      return GateVerdict.notAccepted;
    }
    final GateRule rule = _rules[ruled]!;
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
    final String? ruled =
        dot < 0 ? null : _ruleCovering(keyName.substring(dot + 1));
    return ruled == null ? null : _rules[ruled];
  }

  /// The nearest namespace at or above [namespace], by P1's suffix match,
  /// that has a rule, or null.
  String? _ruleCovering(String namespace) {
    for (final String candidate in _covering(namespace)) {
      if (_rules[candidate]!.mode != null) {
        return candidate;
      }
    }
    return null;
  }

  /// The namespaces at or above [namespace], by P1's suffix match, that the
  /// gate holds an entry for, the most specific first.
  Iterable<String> _covering(String namespace) sync* {
    String? candidate = namespace;
    while (candidate != null) {
      if (_rules.containsKey(candidate)) {
        yield candidate;
      }
      final int dot = candidate.indexOf('.');
      candidate = dot < 0 ? null : candidate.substring(dot + 1);
    }
  }

  /// Whether [other] is admitted somewhere the admission takes effect: in a
  /// rule's admitted set, among the admissions recorded on a namespace no rule
  /// covers, or in the atSign-wide admitted set.
  bool isAdmittedSomewhere(Atsign other) =>
      _admittedEverywhere.contains(other) ||
      _rules.entries.any((entry) =>
          entry.value.admitted.contains(other) &&
          (entry.value.mode != null || _ruleCovering(entry.key) == null));

  /// [namespace]'s rule and sets, or the atSign-wide admitted set when
  /// [namespace] is [everyNamespace], as `gate:show` answers them.
  Map<String, Object?> show(String namespace) {
    if (namespace == everyNamespace) {
      return {'namespace': namespace, 'admitted': _sorted(_admittedEverywhere)};
    }
    final GateRule? rule = _rules[namespace];
    final GateMode? mode = rule?.mode;
    if (mode == null) {
      final String? governedBy = _ruleCovering(namespace);
      return {
        'namespace': namespace,
        'mode': 'none',
        'default': _default.name,
        'admitted': _sorted(rule?.admitted ?? const {}),
        if (governedBy != null) 'governedBy': governedBy,
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
      if (mode == GateMode.open) 'quarantined': _showQuarantined(namespace),
    };
  }

  List<Map<String, Object?>> _showQuarantined(String namespace) {
    final List<MapEntry<Atsign, QuarantineEntry>> entries =
        quarantinedIn(namespace).entries.toList()
          ..sort((a, b) => a.value.firstContact.compareTo(b.value.firstContact));
    return [
      for (final MapEntry<Atsign, QuarantineEntry> e in entries)
        {
          'atSign': '${e.key}',
          'counted': e.value.counted.length,
          'bytes': e.value.bytes,
          'firstContact': e.value.firstContact.toUtc().toIso8601String(),
        }
    ];
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
        if (mode == GateMode.closed) {
          await _dropQuarantine(namespace);
        } else if (admit != null) {
          await _endCounting(namespace, admit);
        }
      });

  /// Takes [namespace]'s rule away, keeping its admitted set as admissions
  /// recorded there; its denied set and settings go. A namespace with no rule
  /// is left as it is.
  Future<void> removeRule(String namespace) => _writes.protect(() async {
        final GateRule? existing = _rules[namespace];
        if (existing?.mode == null) {
          return;
        }
        if (existing!.admitted.isEmpty) {
          await _store?.deleteRule(namespace);
          _rules.remove(namespace);
        } else {
          await _putRule(
              namespace, GateRule(null, admitted: {...existing.admitted}));
        }
        await _dropQuarantine(namespace);
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
          for (final String quarantined in [..._quarantine.keys]) {
            await _endCounting(quarantined, other);
          }
          return;
        }
        final GateRule rule =
            _rules[namespace]?.copy() ?? _newEntry(namespace);
        _addAdmitted(namespace, rule, other);
        await _putRule(namespace, rule);
        await _endCounting(namespace, other);
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
        await _endCounting(namespace, other);
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

  Future<void> _putQuarantine(
      String namespace, Map<Atsign, QuarantineEntry> entries) async {
    if (entries.isEmpty) {
      await _dropQuarantine(namespace);
      return;
    }
    await _store?.putQuarantine(namespace, entries);
    _quarantine[namespace] = entries;
  }

  Future<void> _dropQuarantine(String namespace) async {
    if (!_quarantine.containsKey(namespace)) {
      return;
    }
    await _store?.deleteQuarantine(namespace);
    _quarantine.remove(namespace);
  }

  /// Ends the counting of [other] in [namespace], when it is quarantined
  /// there.
  Future<void> _endCounting(String namespace, Atsign other) async {
    final Map<Atsign, QuarantineEntry>? entries = _quarantine[namespace];
    if (entries == null || !entries.containsKey(other)) {
      return;
    }
    await _putQuarantine(namespace, {...entries}..remove(other));
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
