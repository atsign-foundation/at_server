import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops_ffi.dart';

/// An ML-DSA-65-signed binding of an X-Wing public key to an expiry timestamp.
///
/// Lives here because the cert is an atServer↔atServer
/// protocol artifact with a single consumer: [PqKeyManager]. See
/// docs/inter-atserver-comms.md.
class XWingCert {
  final Uint8List xwingPublicKey;
  final DateTime validUntil;
  final Uint8List signature;

  /// The ML-DSA-65 public key that [signature] verifies against, carried
  /// inside the cert so a peer can fetch cert + signing key in one lookup.
  /// This does not weaken trust: both records are self-asserted by the same
  /// secondary server, so embedding one in the other's signed payload is no
  /// less trustworthy than fetching them separately.
  final Uint8List mlDsaPublicKey;

  const XWingCert({
    required this.xwingPublicKey,
    required this.validUntil,
    required this.signature,
    required this.mlDsaPublicKey,
  });

  /// To-be-signed bytes (X.509 convention): the canonical payload the signer
  /// covers — `xwingPublicKey || utf8(validUntil ISO-8601 UTC) || mlDsaPublicKey`.
  Uint8List get tbsBytes => Uint8List.fromList([
        ...xwingPublicKey,
        ...utf8.encode(validUntil.toUtc().toIso8601String()),
        ...mlDsaPublicKey,
      ]);

  /// Parse a JSON string produced by [toJson]. Returns `null` on any error.
  static XWingCert? tryParse(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      return XWingCert(
        xwingPublicKey: base64.decode(m['xwingPublicKey'] as String),
        validUntil: DateTime.parse(m['validUntil'] as String),
        signature: base64.decode(m['signature'] as String),
        mlDsaPublicKey: base64.decode(m['mlDsaPublicKey'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  String toJson() => jsonEncode({
        'xwingPublicKey': base64.encode(xwingPublicKey),
        'validUntil': validUntil.toUtc().toIso8601String(),
        'signature': base64.encode(signature),
        'mlDsaPublicKey': base64.encode(mlDsaPublicKey),
      });

  /// Strict verification: not expired, and [signature] verifies against
  /// [mlDsaPublicKey] over [tbsBytes].
  Future<bool> verify() async {
    if (validUntil.isBefore(DateTime.now().toUtc())) return false;
    return AtPqc.mlDsa65
        .verifyBytes(tbsBytes, signature: signature, publicKey: mlDsaPublicKey);
  }
}
