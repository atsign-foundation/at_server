import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_telemetry/at_telemetry.dart';
import 'package:at_utils/at_logger.dart';

import 'at_server_telemetry_key_guard.dart';

// The atServer's own Ed25519 key for signing telemetry. The secret is its
// 32-byte seed in base64 under a reserved privatekey: name, so llookup cannot
// address it, scan strips it and the commit log never records it. The public
// half is a hidden public:_<name>.__atserver record that an unauthenticated
// lookup still serves.
final class AtServerTelemetrySigningKey {
  static final AtSignLogger _logger =
      AtSignLogger('AtServerTelemetrySigningKey');

  final AtTelemetryEd25519Signer signer;
  final AtTelemetryPublicKeyRecord publicKeyRecord;

  AtServerTelemetrySigningKey._(this.signer, this.publicKeyRecord);

  // Creates the key on first use, and rewrites the public record whenever it
  // does not match the secret
  static Future<AtServerTelemetrySigningKey> loadOrCreate(
    AtKeyValueStore<String, AtData, AtMetaData?> keyStore,
    String atSign, {
    Random? random,
  }) async {
    AtTelemetryEd25519Signer? signer = await _load(keyStore);
    if (signer == null) {
      signer = await AtTelemetryEd25519Signer.generate(random: random);
      await keyStore.put(
        AtServerTelemetryKeyGuard.secretKey,
        AtData()..data = base64Encode(signer.seed),
        skipCommit: true,
      );
      _logger.info('Generated a telemetry signing key');
    }

    final AtTelemetryPublicKeyRecord record = AtTelemetryPublicKeyRecord(
      algorithm: signer.algorithm,
      publicKey: signer.publicKey,
    );
    final String recordKey = AtServerTelemetryKeyGuard.publicRecordKey(atSign);
    if (await _read(keyStore, recordKey) != record.encode()) {
      await keyStore.put(
        recordKey,
        AtData()..data = record.encode(),
        skipCommit: true,
      );
      _logger.info('Published telemetry key ${record.keyId}');
    }
    return AtServerTelemetrySigningKey._(signer, record);
  }

  String get keyId => publicKeyRecord.keyId;

  static Future<AtTelemetryEd25519Signer?> _load(
    AtKeyValueStore<String, AtData, AtMetaData?> keyStore,
  ) async {
    final String? stored =
        await _read(keyStore, AtServerTelemetryKeyGuard.secretKey);
    if (stored == null) {
      return null;
    }
    try {
      return await AtTelemetryEd25519Signer.fromSeed(base64Decode(stored));
    } on Object catch (error) {
      _logger.warning('Replacing an unreadable telemetry signing key: '
          '${error.runtimeType}');
      return null;
    }
  }

  static Future<String?> _read(
    AtKeyValueStore<String, AtData, AtMetaData?> keyStore,
    String key,
  ) async {
    try {
      return (await keyStore.get(key))?.data;
    } on KeyNotFoundException {
      return null;
    }
  }
}
