/// The ordered `:tag:value` metadata fragment embedded in `update`,
/// `update:meta`, and `notify`.
///
/// Source: `VerbSyntax.metadataFragment` (at_commons `syntax.dart:37-60`).
/// Every field is optional on the wire; `null` means the tag was absent,
/// which is distinct from any explicit value (e.g. `ttl:0`). Fields are
/// declared in wire order.
final class MetadataFragment {
  /// `ttl` — time-to-live in ms. Sign is syntactically allowed.
  final int? ttl;

  /// `ttb` — time-to-birth in ms. Sign is syntactically allowed.
  final int? ttb;

  /// `ttr` — cache refresh interval in ms; `-1` means cache forever.
  final int? ttr;

  /// `ccd` — cascade-delete cached copies.
  final bool? ccd;

  /// `cAt`.
  final DateTime? createdAt;

  /// `uAt`.
  final DateTime? updatedAt;

  /// `eAt`.
  final DateTime? expiresAt;

  /// `aAt`.
  final DateTime? availableAt;

  final String? dataSignature;
  final String? sharedKeyStatus;
  final bool? isBinary;
  final bool? isEncrypted;
  final String? sharedKeyEnc;

  /// Deprecated predecessor of [pubKeyHash].
  final String? pubKeyCS;
  final String? pubKeyHash;
  final String? hashingAlgo;
  final String? encoding;
  final String? encKeyName;
  final String? encAlgo;
  final String? ivNonce;
  final String? skeEncKeyName;
  final String? skeEncAlgo;
  final bool? immutable;

  /// Opaque app-level metadata, kept as the raw wire token.
  final String? appMetadata;

  const MetadataFragment({
    this.ttl,
    this.ttb,
    this.ttr,
    this.ccd,
    this.createdAt,
    this.updatedAt,
    this.expiresAt,
    this.availableAt,
    this.dataSignature,
    this.sharedKeyStatus,
    this.isBinary,
    this.isEncrypted,
    this.sharedKeyEnc,
    this.pubKeyCS,
    this.pubKeyHash,
    this.hashingAlgo,
    this.encoding,
    this.encKeyName,
    this.encAlgo,
    this.ivNonce,
    this.skeEncKeyName,
    this.skeEncAlgo,
    this.immutable,
    this.appMetadata,
  });

  /// All fields in wire order, for equality and hashing.
  List<Object?> get _fields => [
        ttl,
        ttb,
        ttr,
        ccd,
        createdAt,
        updatedAt,
        expiresAt,
        availableAt,
        dataSignature,
        sharedKeyStatus,
        isBinary,
        isEncrypted,
        sharedKeyEnc,
        pubKeyCS,
        pubKeyHash,
        hashingAlgo,
        encoding,
        encKeyName,
        encAlgo,
        ivNonce,
        skeEncKeyName,
        skeEncAlgo,
        immutable,
        appMetadata,
      ];

  /// True when no tag was present.
  bool get isEmpty => _fields.every((field) => field == null);

  @override
  bool operator ==(Object other) {
    if (other is! MetadataFragment) return false;
    final mine = _fields, theirs = other._fields;
    for (var i = 0; i < mine.length; i++) {
      if (mine[i] != theirs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_fields);

  @override
  String toString() => 'MetadataFragment(ttl: $ttl, ttb: $ttb, ttr: $ttr, '
      'ccd: $ccd, createdAt: $createdAt, updatedAt: $updatedAt, '
      'expiresAt: $expiresAt, availableAt: $availableAt, '
      'dataSignature: $dataSignature, sharedKeyStatus: $sharedKeyStatus, '
      'isBinary: $isBinary, isEncrypted: $isEncrypted, '
      'sharedKeyEnc: $sharedKeyEnc, pubKeyCS: $pubKeyCS, '
      'pubKeyHash: $pubKeyHash, hashingAlgo: $hashingAlgo, '
      'encoding: $encoding, encKeyName: $encKeyName, encAlgo: $encAlgo, '
      'ivNonce: $ivNonce, skeEncKeyName: $skeEncKeyName, '
      'skeEncAlgo: $skeEncAlgo, immutable: $immutable, '
      'appMetadata: $appMetadata)';
}
