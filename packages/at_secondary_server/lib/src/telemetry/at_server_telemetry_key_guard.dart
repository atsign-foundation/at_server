import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

// Decides which keys and namespaces belong to the atServer's telemetry
// signing key. Only the atServer itself writes them, straight through its
// keystore, so every verb that would mutate one is refused, for CRAM too.
final class AtServerTelemetryKeyGuard {
  // ignore: experimental_member_use
  static const String secretKey = AtConstants.atTelemetrySigningPrivateKey;
  // Followed by the atSign
  static const String publicRecordName =
      // ignore: experimental_member_use
      AtConstants.atTelemetrySigningPublicKey;
  static const String refusal = 'The telemetry signing key and its public '
      'record are written only by the atServer itself';
  static const String namespaceRefusal = 'The '
      '${AtConstants.atServerReservedNamespace} namespace is written only by '
      'the atServer itself';
  static final RegExp _publicRecordPattern =
      RegExp('^${RegExp.escape(publicRecordName)}@[^@:\\s]+\$');

  const AtServerTelemetryKeyGuard._();

  // atKey in any spelling the keystore folds to one of the two records
  static bool isTelemetryKey(String atKey) {
    final String key = canonicalAtKey(atKey);
    return key == secretKey || _publicRecordPattern.hasMatch(key);
  }

  // __atserver itself, or any namespace ending in it
  static bool isAtServerNamespace(String namespace) {
    final String folded = canonicalAtKey(namespace);
    return folded == AtConstants.atServerReservedNamespace ||
        folded.endsWith('.${AtConstants.atServerReservedNamespace}');
  }

  static String publicRecordKey(String atSign) => '$publicRecordName$atSign';
}
