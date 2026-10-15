import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/enroll/enroll_datastore_value.dart';
import 'package:at_secondary/src/enroll/enrollment_access.dart';
import 'package:at_secondary/src/gate/gatekeeper.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// Sets and reads the atSign's gate.
///
/// A namespace's gate takes `rw` on the namespace to change and `r` to read;
/// the default and the atSign-wide admitted set take a root connection.
class GateVerbHandler extends AbstractVerbHandler {
  static final Gate _gate = Gate();

  GateVerbHandler(super.keyStore);

  @override
  bool accept(String command) => command.startsWith('gate:');

  @override
  Verb getVerb() => _gate;

  @override
  Future<void> processVerb(Response response,
      HashMap<String, String?> verbParams, InboundConnection atConnection) async {
    final Gatekeeper gatekeeper = AtSecondaryServerImpl.getInstance().gatekeeper;
    final InboundConnectionMetadata metadata =
        atConnection.metaData as InboundConnectionMetadata;

    if (verbParams[AtConstants.gateDefault] != null) {
      final String? mode = verbParams[AtConstants.gateDefaultMode];
      if (mode == null) {
        response.data = gatekeeper.defaultMode.name;
        return;
      }
      await _requireRoot(metadata, 'switch the default');
      await gatekeeper.setDefault(GateDefault.values.byName(mode));
      response.data = 'success';
      return;
    }

    if (verbParams[AtConstants.gateRule] != null) {
      final String namespace =
          verbParams[AtConstants.gateRuleNamespace]!.toLowerCase();
      await _requireAccess(metadata, namespace, write: true);
      if (verbParams[AtConstants.gateNone] != null) {
        await gatekeeper.removeRule(namespace);
        response.data = 'success';
        return;
      }
      final String? setting = verbParams[AtConstants.gateSetting];
      final String? value = verbParams[AtConstants.gateSettingValue];
      final String? admit = verbParams[AtConstants.gateAdmit];
      await gatekeeper.setRule(
          namespace,
          verbParams[AtConstants.gateOpen] != null
              ? GateMode.open
              : GateMode.closed,
          setting: setting == null ? null : GateSetting.values.byName(setting),
          value: value == null || value == 'default' ? null : int.parse(value),
          admit: admit?.toAtsign());
      response.data = 'success';
      return;
    }

    if (verbParams[AtConstants.gateSetOperation] != null) {
      final String namespace =
          verbParams[AtConstants.gateSetNamespace]!.toLowerCase();
      if (namespace == Gatekeeper.everyNamespace) {
        await _requireRoot(metadata, 'change the atSign-wide admitted set');
      } else {
        await _requireAccess(metadata, namespace, write: true);
      }
      final Atsign other = verbParams[AtConstants.gateSetAtSign]!.toAtsign();
      switch (verbParams[AtConstants.gateSetOperation]) {
        case 'admit':
          await gatekeeper.admit(namespace, other);
        case 'deny':
          await gatekeeper.deny(namespace, other);
        default:
          await gatekeeper.remove(namespace, other);
      }
      response.data = 'success';
      return;
    }

    if (verbParams[AtConstants.gateShow] != null) {
      final String namespace =
          verbParams[AtConstants.gateShowNamespace]!.toLowerCase();
      if (namespace == Gatekeeper.everyNamespace) {
        await _requireRoot(metadata, 'read the atSign-wide admitted set');
      } else {
        await _requireAccess(metadata, namespace, write: false);
      }
      response.data = jsonEncode(gatekeeper.show(namespace));
      return;
    }

    if (verbParams[AtConstants.gateCheck] != null) {
      final String namespace =
          verbParams[AtConstants.gateCheckNamespace]!.toLowerCase();
      await _requireAccess(metadata, namespace, write: false);
      final Atsign other = verbParams[AtConstants.gateCheckAtSign]!.toAtsign();
      final GateVerdict verdict =
          other == AtSecondaryServerImpl.getInstance().currentAtSign
              ? GateVerdict.admitted
              : gatekeeper.check(namespace, other);
      response.data = jsonEncode({
        'namespace': namespace,
        'atSign': '$other',
        'verdict': verdict.name,
      });
      return;
    }

    response.data = jsonEncode(await _listable(metadata, gatekeeper.namespaces));
  }

  /// The [namespaces] this connection may read: all of them to a root
  /// connection, and those its enrollment holds to any other.
  Future<List<String>> _listable(
      InboundConnectionMetadata metadata, List<String> namespaces) async {
    if (await _isRoot(metadata)) {
      return namespaces;
    }
    final EnrollDataStoreValue? enrollment = await _enrollmentOf(metadata);
    if (enrollment == null) {
      throw UnAuthorizedException('This connection may not list the gate');
    }
    return [
      for (final String namespace in namespaces)
        if (EnrollmentAccess.allowsRead(enrolledAccessFor(enrollment, namespace)))
          namespace
    ];
  }

  Future<bool> _isRoot(InboundConnectionMetadata metadata) async {
    if (AbstractVerbHandler.isCramConnection(metadata)) {
      return true;
    }
    final EnrollDataStoreValue? enrollment = await _enrollmentOf(metadata);
    return enrollment != null &&
        EnrollmentAccess.allowsWrite(enrollment.namespaces['*']) &&
        EnrollmentAccess.allowsWrite(
            enrollment.namespaces[EnrollmentConstants.enrollManageNamespace]);
  }

  Future<void> _requireRoot(
      InboundConnectionMetadata metadata, String action) async {
    if (!await _isRoot(metadata)) {
      throw UnAuthorizedException('Only a root connection may $action');
    }
  }

  Future<void> _requireAccess(InboundConnectionMetadata metadata,
      String namespace, {required bool write}) async {
    if (AbstractVerbHandler.isCramConnection(metadata)) {
      return;
    }
    final EnrollDataStoreValue? enrollment = await _enrollmentOf(metadata);
    final String? access =
        enrollment == null ? null : enrolledAccessFor(enrollment, namespace);
    final bool allowed = write
        ? EnrollmentAccess.allowsWrite(access)
        : EnrollmentAccess.allowsRead(access);
    if (!allowed) {
      throw UnAuthorizedException(
          'This enrollment may not ${write ? 'change' : 'read'} the gate of'
          ' $namespace');
    }
  }

  Future<EnrollDataStoreValue?> _enrollmentOf(
      InboundConnectionMetadata metadata) async {
    final String? enrollmentId = metadata.enrollmentId;
    return enrollmentId == null ? null : await resolveEnrollment(enrollmentId);
  }
}
