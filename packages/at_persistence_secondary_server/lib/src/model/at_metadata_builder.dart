import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

/// Builder class to build [AtMetaData] object.
class AtMetadataBuilder {
  late final AtMetaData atMetaData;

  /// We will constrain to millisecond precision because Hive only stores
  /// [DateTime]s to millisecond precision - see https://github.com/hivedb/hive/issues/474
  /// for details.
  final DateTime currentUtcTimeToMillisecondPrecision =
      DateTime.now().toUtcMillisecondsPrecision();

  static final AtSignLogger logger = AtSignLogger('AtMetadataBuilder');

  AtMetadataBuilder(
      {String? atSign, AtMetaData? newMetaData, AtMetaData? existingMetaData})
      : atMetaData = newMetaData ?? AtMetaData() {
    // createdAt indicates the date and time of the key created.
    // For a new key, the currentDateTime is set and remains unchanged
    // on an update event.
    atMetaData.createdAt =
        existingMetaData?.createdAt ?? currentUtcTimeToMillisecondPrecision;
    atMetaData.createdBy ??= atSign;
    atMetaData.updatedBy = atSign;

    // updatedAt indicates the date and time of the key updated.
    // For a new key, the updatedAt is same as createdAt and on key
    // update, set the updatedAt to the currentDateTime.
    atMetaData.updatedAt = currentUtcTimeToMillisecondPrecision;
    atMetaData.status = 'active';

    // sets newAtMetaData attributes if set. Otherwise fallback to existingMetaData attributes.
    _copyMetadata(existingMetaData, newMetaData);

    if (atMetaData.ttl != null && atMetaData.ttl! >= 0) {
      setTTL(atMetaData.ttl, ttb: atMetaData.ttb);
    }
    if (atMetaData.ttb != null && atMetaData.ttb! >= 0) {
      setTTB(atMetaData.ttb);
    }
    // If TTR is -1, cache the key forever.
    if (atMetaData.ttr != null && atMetaData.ttr! > 0 || atMetaData.ttr == -1) {
      setTTR(atMetaData.ttr);
    }
  }

  void _copyMetadata(AtMetaData? existingMetaData, AtMetaData? newAtMetaData) {
    atMetaData.ttl = _getOrDefault(newAtMetaData?.ttl, existingMetaData?.ttl);
    atMetaData.ttb = newAtMetaData?.ttb ?? existingMetaData?.ttb;
    atMetaData.ttr = newAtMetaData?.ttr ?? existingMetaData?.ttr;
    atMetaData.isCascade =
        newAtMetaData?.isCascade ?? existingMetaData?.isCascade;
    atMetaData.isBinary = newAtMetaData?.isBinary ?? existingMetaData?.isBinary;
    atMetaData.isEncrypted =
        newAtMetaData?.isEncrypted ?? existingMetaData?.isEncrypted;
    atMetaData.dataSignature = newAtMetaData?.dataSignature == "null"
        ? null
        : newAtMetaData?.dataSignature ?? existingMetaData?.dataSignature;
    atMetaData.sharedKeyEnc = newAtMetaData?.sharedKeyEnc == "null"
        ? null
        : newAtMetaData?.sharedKeyEnc ?? existingMetaData?.sharedKeyEnc;
    atMetaData.pubKeyCS = newAtMetaData?.pubKeyCS == "null"
        ? null
        : newAtMetaData?.pubKeyCS ?? existingMetaData?.pubKeyCS;

    atMetaData.encoding = newAtMetaData?.encoding == "null"
        ? null
        : newAtMetaData?.encoding ?? existingMetaData?.encoding;
    atMetaData.encKeyName = newAtMetaData?.encKeyName == "null"
        ? null
        : newAtMetaData?.encKeyName ?? existingMetaData?.encKeyName;
    atMetaData.encAlgo = newAtMetaData?.encAlgo == "null"
        ? null
        : newAtMetaData?.encAlgo ?? existingMetaData?.encAlgo;
    atMetaData.ivNonce = newAtMetaData?.ivNonce == "null"
        ? null
        : newAtMetaData?.ivNonce ?? existingMetaData?.ivNonce;
    atMetaData.skeEncKeyName = newAtMetaData?.skeEncKeyName == "null"
        ? null
        : newAtMetaData?.skeEncKeyName ?? existingMetaData?.skeEncKeyName;
    atMetaData.skeEncAlgo = newAtMetaData?.skeEncAlgo == "null"
        ? null
        : newAtMetaData?.skeEncAlgo ?? existingMetaData?.skeEncAlgo;
    atMetaData.version = newAtMetaData?.version ?? existingMetaData?.version;
  }

  int? _getOrDefault(int? newValue, int? existingValue) =>
      newValue ?? existingValue;

  void setTTL(int? ttl, {int? ttb}) {
    if (ttl != null) {
      atMetaData.ttl = ttl;
      atMetaData.expiresAt = _getExpiresAt(
          currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttl,
          ttb: ttb);
    }
  }

  void setTTB(int? ttb) {
    if (ttb != null) {
      atMetaData.ttb = ttb;
      atMetaData.availableAt = _getAvailableAt(
          currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttb);
      logger
          .finer('setTTB($ttb) - set availableAt to ${atMetaData.availableAt}');
    }
  }

  void setTTR(int? ttr) {
    if (ttr != null) {
      atMetaData.ttr = ttr;
      atMetaData.refreshAt =
          _getRefreshAt(currentUtcTimeToMillisecondPrecision, ttr);
    }
  }

  void setCCD(bool ccd) {
    atMetaData.isCascade = ccd;
  }

  DateTime? _getAvailableAt(int epochNow, int ttb) =>
      DateTime.fromMillisecondsSinceEpoch(epochNow + ttb).toUtc();

  DateTime? _getExpiresAt(int epochNow, int ttl, {int? ttb}) {
    if (ttl == 0) return null; // Key will not expire if TTL is 0
    var expiresAt = epochNow + ttl + (ttb ?? 0);
    return DateTime.fromMillisecondsSinceEpoch(expiresAt).toUtc();
  }

  DateTime? _getRefreshAt(DateTime today, int ttr) =>
      ttr == -1 ? null : today.add(Duration(seconds: ttr));

  AtMetaData build() => atMetaData;
}
