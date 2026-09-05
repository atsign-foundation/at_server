import 'package:at_chops/at_chops.dart';

/// A fresh RSA-2048 APKAM keypair for ONE enrollment.
///
/// Every enrollment a test creates gets its own keypair, as a real enrollment
/// does. The demo maps in at_demo_data carry one APKAM keypair and one legacy
/// PKAM keypair per atSign; passing either as an enrollment's
/// `apkamPublicKey` makes every enrollment in the pack, and the atSign's own
/// credential, one key held under many names, so nothing in the pack can tell
/// which of them authenticated. A retrofit successor gets its own keypair
/// too: a retrofit is a re-key.
///
/// [publicKey] is the string an `enroll:request` carries as `apkamPublicKey`;
/// [privateKey] is what signs the `pkam:` challenge for that enrollment, and
/// is what `OutboundConnectionFactory.authenticateConnection` takes as
/// `privateKey` for `AuthType.apkam`. [pair] is the same keypair as at_chops
/// holds it, for tests that sign something else with it (a rotation's proof
/// of possession, for instance). Both strings are in the spelling the demo
/// maps use, base64 DER, which is what the atServer verifies `rsa2048`
/// signatures against.
class ApkamKeys {
  final RsaKeyPair pair;

  ApkamKeys(this.pair);

  String get publicKey => pair.atPublicKey.publicKey;

  String get privateKey => pair.atPrivateKey.privateKey;
}

/// Mints an [ApkamKeys] nobody else holds.
ApkamKeys mintApkamKeys() => ApkamKeys(RsaKeyPair.generate());
