part of '../command.dart';

/// `from:<atSign>[:clientConfig:<json>]`
///
/// Source: `VerbSyntax.from` (at_commons `syntax.dart:5-6`).
final class FromCommand extends Command {
  /// The legacy regex accepts this with or without `@`; stored without.
  final String atSign;

  /// Raw `clientConfig` JSON object.
  final String? clientConfig;

  const FromCommand({required this.atSign, this.clientConfig});

  @override
  Map<String, Object?> get _fields =>
      {'atSign': atSign, 'clientConfig': clientConfig};
}

/// `pol` — no arguments.
///
/// Source: `VerbSyntax.pol` (at_commons `syntax.dart:7`).
final class PolCommand extends Command {
  const PolCommand();

  @override
  Map<String, Object?> get _fields => const {};
}

/// `cram:<digest>`
///
/// Source: `VerbSyntax.cram` (at_commons `syntax.dart:8`).
final class CramCommand extends Command {
  final String digest;

  const CramCommand({required this.digest});

  @override
  Map<String, Object?> get _fields => {'digest': digest};
}

/// `pkam:[signingAlgo:<algo>:][hashingAlgo:<algo>:][enrollmentId:<id>:]<signature>`
///
/// Source: `VerbSyntax.pkam` (at_commons `syntax.dart:9-10`). Absent algos
/// default to `rsa2048`/`sha256` server-side; that default is applied by
/// validation, not here.
final class PkamCommand extends Command {
  final SigningAlgo? signingAlgo;
  final HashingAlgo? hashingAlgo;
  final String? enrollmentId;
  final String signature;

  const PkamCommand({
    required this.signature,
    this.signingAlgo,
    this.hashingAlgo,
    this.enrollmentId,
  });

  @override
  Map<String, Object?> get _fields => {
        'signingAlgo': signingAlgo,
        'hashingAlgo': hashingAlgo,
        'enrollmentId': enrollmentId,
        'signature': signature,
      };
}
