import 'dart:convert';
import 'dart:typed_data';

import 'package:at_chops/at_chops.dart';

/// The id this test registers [fakeStrongerAlgo] under in
/// `SigningKeyManager.withAlgos` — at_server assigns it, exactly as
/// [negotiableSigningAlgos] assigns `polAlgoMlDsa65` to the real algorithm.
const String fakeStrongerAlgoId = 'test-stronger-algo';

/// A stand-in [AtSignatureAlgorithm] used to exercise negotiation across more
/// than one algorithm.
///
/// at_chops ships exactly one PQ signature algorithm today, so without a
/// stand-in the interesting behaviour — picking the strongest type both ends
/// support, falling back to a weaker one, ignoring a type we do not know — would
/// ship completely unexercised. Placed ahead of the real entries (see the
/// second-algorithm group in `outbound_client_pq_signing_test.dart`), it
/// becomes the "strongest", so preference order becomes observable.
///
/// The scheme is deliberately trivial (and useless cryptographically): what is
/// under test is negotiation and plumbing, not a primitive. It is also
/// structurally distinct from the real primitive on purpose — a differential
/// oracle. Two negotiable entries resolving to the *same* underlying algorithm
/// would let a bug that resolves the wrong entry still produce a valid
/// signature; this one fails loudly instead, because a wrong-entry signature
/// here decodes to the wrong secret key material.
final class _FakeStrongerAtSignatureAlgorithm implements AtSignatureAlgorithm {
  const _FakeStrongerAtSignatureAlgorithm();

  @override
  String get name => fakeStrongerAlgoId;

  @override
  Future<({Uint8List publicKey, Uint8List secretKey})> generateKeyPair() async =>
      (publicKey: utf8.encode('fake-pub'), secretKey: utf8.encode('fake-sec'));

  /// "Signs" by pairing the secret key with the message. Verification then
  /// checks the message matches, so a wrong message fails exactly as a real
  /// signature would — which is what the negotiation tests rely on.
  @override
  Future<Uint8List> signBytes(Uint8List message,
          {required Uint8List secretKey}) async =>
      Uint8List.fromList([...secretKey, 0x7c /* '|' */, ...message]);

  @override
  Future<bool> verifyBytes(Uint8List message,
      {required Uint8List signature, required Uint8List publicKey}) async {
    final sep = signature.indexOf(0x7c);
    if (sep < 0) return false;
    final msg = signature.sublist(sep + 1);
    return msg.length == message.length &&
        [for (var i = 0; i < msg.length; i++) msg[i] == message[i]]
            .every((eq) => eq);
  }
}

const AtSignatureAlgorithm fakeStrongerAlgo = _FakeStrongerAtSignatureAlgorithm();
