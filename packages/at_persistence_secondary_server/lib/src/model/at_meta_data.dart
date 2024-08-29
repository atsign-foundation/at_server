import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

class AtMetaData {
  String? createdBy;

  String? updatedBy;

  DateTime? createdAt;

  DateTime? updatedAt;

  DateTime? expiresAt;

  String? status;

  int? version;

  DateTime? availableAt;

  int? ttb;

  int? ttl;

  int? ttr;

  DateTime? refreshAt;

  bool? isCascade;

  bool? isBinary;

  bool? isEncrypted;

  String? dataSignature;

  String? sharedKeyEnc;

  String? pubKeyCS;

  String? encoding;

  String? encKeyName;

  String? encAlgo;

  String? ivNonce;

  String? skeEncKeyName;

  String? skeEncAlgo;

  @override
  String toString() {
    return toJson().toString();
  }

  AtMetaData();

  Metadata toCommonsMetadata() {
    return Metadata()
      ..ttl = ttl
      ..ttb = ttb
      ..ttr = ttr
      ..ccd = isCascade
      ..isBinary = (isBinary == null) ? false : isBinary!
      ..isEncrypted = (isEncrypted == null) ? false : isEncrypted!
      ..dataSignature = dataSignature
      ..sharedKeyEnc = sharedKeyEnc
      ..pubKeyCS = pubKeyCS
      ..encoding = encoding
      ..encKeyName = encKeyName
      ..encAlgo = encAlgo
      ..ivNonce = ivNonce
      ..skeEncKeyName = skeEncKeyName
      ..skeEncAlgo = skeEncAlgo;
  }

  factory AtMetaData.fromCommonsMetadata(Metadata metadata) {
    var atMetadata = AtMetaData();
    atMetadata
      ..ttl = metadata.ttl
      ..ttb = metadata.ttb
      ..ttr = metadata.ttr
      ..isCascade = metadata.ccd
      ..isBinary = metadata.isBinary
      ..isEncrypted = metadata.isEncrypted
      ..dataSignature = metadata.dataSignature
      ..sharedKeyEnc = metadata.sharedKeyEnc
      ..pubKeyCS = metadata.pubKeyCS
      ..encoding = metadata.encoding
      ..encKeyName = metadata.encKeyName
      ..encAlgo = metadata.encAlgo
      ..ivNonce = metadata.ivNonce
      ..skeEncKeyName = metadata.skeEncKeyName
      ..skeEncAlgo = metadata.skeEncAlgo;
    return AtMetadataBuilder(newAtMetaData: atMetadata).build();
  }

  Map toJson() {
    // ignore: omit_local_variable_types
    Map map = {};
    map['createdBy'] = createdBy;
    map['updatedBy'] = updatedBy;
    map['createdAt'] = createdAt?.toUtc().toString();
    map['updatedAt'] = updatedAt?.toUtc().toString();
    map['availableAt'] = availableAt?.toUtc().toString();
    map['expiresAt'] = expiresAt?.toUtc().toString();
    map['refreshAt'] = refreshAt?.toUtc().toString();
    map['status'] = status;
    map['version'] = version;
    map[AtConstants.ttl] = ttl;
    map[AtConstants.ttb] = ttb;
    map[AtConstants.ttr] = ttr;
    map[AtConstants.ccd] = isCascade;
    map[AtConstants.isBinary] = isBinary;
    map[AtConstants.isEncrypted] = isEncrypted;
    map[AtConstants.publicDataSignature] = dataSignature;
    map[AtConstants.sharedKeyEncrypted] = sharedKeyEnc;
    map[AtConstants.sharedWithPublicKeyCheckSum] = pubKeyCS;
    map[AtConstants.encoding] = encoding;
    map[AtConstants.encryptingKeyName] = encKeyName;
    map[AtConstants.encryptingAlgo] = encAlgo;
    map[AtConstants.ivOrNonce] = ivNonce;
    map[AtConstants.sharedKeyEncryptedEncryptingKeyName] = skeEncKeyName;
    map[AtConstants.sharedKeyEncryptedEncryptingAlgo] = skeEncAlgo;
    return map;
  }

  factory AtMetaData.fromJson(Map json) {
    return AtMetaData().fromJson(json);
  }

  AtMetaData fromJson(Map json) {
    createdBy = json['createdBy'];
    updatedBy = json['updatedBy'];
    createdAt =
        json['createdAt'] != null ? DateTime.parse(json['createdAt']) : null;
    updatedAt =
        json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : null;
    expiresAt = (json['expiresAt'] == null || json['expiresAt'] == 'null')
        ? null
        : DateTime.parse(json['expiresAt']);
    refreshAt = (json['refreshAt'] == null || json['refreshAt'] == 'null')
        ? null
        : DateTime.parse(json['refreshAt']);
    availableAt = (json['availableAt'] == null || json['availableAt'] == 'null')
        ? null
        : DateTime.parse(json['availableAt']);
    status = json['status'];
    version = (json['version'] is String)
        ? int.parse(json['version'])
        : (json['version'] == null)
            ? 0
            : json['version'];
    ttl = (json[AtConstants.ttl] is String)
        ? int.parse(json[AtConstants.ttl])
        : (json[AtConstants.ttl] == null)
            ? null
            : json[AtConstants.ttl];
    ttb = (json[AtConstants.ttb] is String)
        ? int.parse(json[AtConstants.ttb])
        : (json[AtConstants.ttb] == null)
            ? null
            : json[AtConstants.ttb];
    ttr = (json[AtConstants.ttr] is String)
        ? int.parse(json[AtConstants.ttr])
        : (json[AtConstants.ttr] == null)
            ? null
            : json[AtConstants.ttr];
    isCascade = json[AtConstants.ccd];
    isBinary = json[AtConstants.isBinary];
    isEncrypted = json[AtConstants.isEncrypted];
    dataSignature = json[AtConstants.publicDataSignature];
    sharedKeyEnc = json[AtConstants.sharedKeyEncrypted];
    pubKeyCS = json[AtConstants.sharedWithPublicKeyCheckSum];
    encoding = json[AtConstants.encoding];
    encKeyName = json[AtConstants.encryptingKeyName];
    encAlgo = json[AtConstants.encryptingAlgo];
    ivNonce = json[AtConstants.ivOrNonce];
    skeEncKeyName = json[AtConstants.sharedKeyEncryptedEncryptingKeyName];
    skeEncAlgo = json[AtConstants.sharedKeyEncryptedEncryptingAlgo];

    return this;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AtMetaData &&
          runtimeType == other.runtimeType &&
          createdBy == other.createdBy &&
          updatedBy == other.updatedBy &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          expiresAt == other.expiresAt &&
          status == other.status &&
          version == other.version &&
          availableAt == other.availableAt &&
          ttb == other.ttb &&
          ttl == other.ttl &&
          ttr == other.ttr &&
          refreshAt == other.refreshAt &&
          isCascade == other.isCascade &&
          isBinary == other.isBinary &&
          isEncrypted == other.isEncrypted &&
          dataSignature == other.dataSignature &&
          sharedKeyEnc == other.sharedKeyEnc &&
          pubKeyCS == other.pubKeyCS &&
          encoding == other.encoding &&
          encKeyName == other.encKeyName &&
          encAlgo == other.encAlgo &&
          ivNonce == other.ivNonce &&
          skeEncKeyName == other.skeEncKeyName &&
          skeEncAlgo == other.skeEncAlgo;

  @override
  int get hashCode =>
      createdBy.hashCode ^
      updatedBy.hashCode ^
      createdAt.hashCode ^
      updatedAt.hashCode ^
      expiresAt.hashCode ^
      status.hashCode ^
      version.hashCode ^
      availableAt.hashCode ^
      ttb.hashCode ^
      ttl.hashCode ^
      ttr.hashCode ^
      refreshAt.hashCode ^
      isCascade.hashCode ^
      isBinary.hashCode ^
      isEncrypted.hashCode ^
      dataSignature.hashCode ^
      sharedKeyEnc.hashCode ^
      pubKeyCS.hashCode ^
      encoding.hashCode ^
      encKeyName.hashCode ^
      encAlgo.hashCode ^
      ivNonce.hashCode ^
      skeEncKeyName.hashCode ^
      skeEncAlgo.hashCode;
}
