part of '../command.dart';

/// `enroll:<operation>[:force][:<listNamespace>][:<enrollParams-json>]`
///
/// Source: `VerbSyntax.enroll` (at_commons `syntax.dart:157-159`).
final class EnrollCommand extends Command {
  final EnrollOperation operation;
  final bool force;
  final String? listNamespace;

  /// Raw `EnrollParams` JSON.
  final String? enrollParams;

  const EnrollCommand({
    required this.operation,
    this.force = false,
    this.listNamespace,
    this.enrollParams,
  });

  @override
  Map<String, Object?> get _fields => {
        'operation': operation,
        'force': force,
        'listNamespace': listNamespace,
        'enrollParams': enrollParams,
      };
}

/// `otp:get[:ttl:<ms>]` or `otp:put[:<otp>][:ttl:<ms>]`
///
/// Source: `VerbSyntax.otp` (at_commons `syntax.dart:160-161`). The regex
/// only captures [otp] after `put`, but doesn't require it there.
final class OtpCommand extends Command {
  final OtpOperation operation;
  final String? otp;
  final int? ttl;

  const OtpCommand({required this.operation, this.otp, this.ttl});

  @override
  Map<String, Object?> get _fields =>
      {'operation': operation, 'otp': otp, 'ttl': ttl};
}

/// `keys:<put|get|delete>[:<visibility>][:namespace:<ns>][:appName:<n>][:deviceName:<n>][:keyType:<t>][:encryptionKeyName:<n>][:keyName:<n> ]<keyValue>`
///
/// Source: `VerbSyntax.keys` (at_commons `syntax.dart:162-170`). Being
/// deprecated.
final class KeysCommand extends Command {
  final KeysOperation operation;
  final KeysVisibility? visibility;
  final String? namespace;
  final String? appName;
  final String? deviceName;
  final String? keyType;
  final String? encryptionKeyName;
  final String? keyName;

  /// Trailing `.*`; always matches, so empty rather than absent.
  final String keyValue;

  const KeysCommand({
    required this.operation,
    this.visibility,
    this.namespace,
    this.appName,
    this.deviceName,
    this.keyType,
    this.encryptionKeyName,
    this.keyName,
    this.keyValue = '',
  });

  @override
  Map<String, Object?> get _fields => {
        'operation': operation,
        'visibility': visibility,
        'namespace': namespace,
        'appName': appName,
        'deviceName': deviceName,
        'keyType': keyType,
        'encryptionKeyName': encryptionKeyName,
        'keyName': keyName,
        'keyValue': keyValue,
      };
}
