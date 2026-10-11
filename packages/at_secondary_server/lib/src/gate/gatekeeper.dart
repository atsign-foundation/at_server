import 'package:at_commons/at_commons.dart';
import 'package:mutex/mutex.dart';

/// How an atSign's gate treats a namespace that has no rule: as today, or
/// closed.
enum GateDefault { ungated, closed }

/// Whether a namespace with a rule lets in an atSign it has not admitted.
enum GateMode { open, closed }

/// The gate's answer for one exchange with another atSign.
enum GateVerdict { admitted, quarantined, notAccepted }

/// A namespace's rule: its mode, and the atSigns admitted and denied in it.
///
/// A closed namespace holds only an admitted set.
class GateRule {
  GateMode mode;
  final Set<Atsign> admitted;
  final Set<Atsign> denied;

  GateRule(this.mode, {Set<Atsign>? admitted, Set<Atsign>? denied})
      : admitted = admitted ?? <Atsign>{},
        denied = denied ?? <Atsign>{};
}

/// An atSign's gate: its default, a rule per namespace, and an atSign-wide
/// admitted set, deciding every exchange with another atSign.
///
/// Every change runs under one mutex; a check only reads, and takes none.
class Gatekeeper {
  /// The namespace a change to the atSign-wide admitted set names.
  static const String everyNamespace = '*';

  GateDefault _default;
  final Map<String, GateRule> _rules = {};
  final Set<Atsign> _admittedEverywhere = {};
  final Mutex _writes = Mutex();

  Gatekeeper({GateDefault defaultMode = GateDefault.ungated})
      : _default = defaultMode;

  GateDefault get defaultMode => _default;

  /// The atSigns admitted in every open namespace.
  Set<Atsign> get admittedEverywhere => Set.unmodifiable(_admittedEverywhere);

  /// The rule set for exactly [namespace], or null.
  GateRule? ruleFor(String namespace) => _rules[namespace];

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

  /// Switches the default for namespaces with no rule.
  Future<void> setDefault(GateDefault mode) =>
      _writes.protect(() async => _default = mode);

  /// Gives [namespace] the rule [mode], keeping the atSigns it has admitted
  /// and admitting [admit] too. Closing a namespace drops its denied set.
  Future<void> setRule(String namespace, GateMode mode, {Atsign? admit}) =>
      _writes.protect(() async {
        final GateRule rule =
            _rules.putIfAbsent(namespace, () => GateRule(mode));
        rule.mode = mode;
        if (mode == GateMode.closed) {
          rule.denied.clear();
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
  /// Throws [IllegalArgumentException] when [namespace] has no rule or is
  /// closed.
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
}
