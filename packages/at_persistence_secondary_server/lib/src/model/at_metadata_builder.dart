import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_utils/at_logger.dart';

/// Builder class to build [AtMetaData] object.
class AtMetadataBuilder {
  late AtMetaData atMetaData;

  /// We will constrain to millisecond precision because Hive only stores
  /// [DateTime]s to millisecond precision - see https://github.com/hivedb/hive/issues/474
  /// for details.
  var currentUtcTimeToMillisecondPrecision =
      DateTime.now().toUtcMillisecondsPrecision();

  static final AtSignLogger logger = AtSignLogger('AtMetadataBuilder');

  AtMetadataBuilder(
      {String? atSign, AtMetaData? newMetaData, AtMetaData? existingMetaData}) {
    newMetaData ??= AtMetaData();
    atMetaData = newMetaData;
    // createdAt indicates the date and time of the key created.
    // For a new key, the currentDateTime is set and remains unchanged
    // on an update event.
    (existingMetaData?.createdAt == null)
        ? atMetaData.createdAt = currentUtcTimeToMillisecondPrecision
        : atMetaData.createdAt = existingMetaData?.createdAt;
    atMetaData.createdBy ??= atSign;
    atMetaData.updatedBy = atSign;
    // updatedAt indicates the date and time of the key updated.
    // For a new key, the updatedAt is same as createdAt and on key
    // update, set the updatedAt to the currentDateTime.
    atMetaData.updatedAt = currentUtcTimeToMillisecondPrecision;
    atMetaData.status = 'active';
    // // The version indicates the number of updates a key has received.
    // // Version is set to 0 for a new key and for each update the key receives,
    // // the version increases by 1
    // (existingMetaData?.version == null)
    //     ? atMetaData.version = 0
    //     : atMetaData.version = (existingMetaData!.version! + 1);

    //If new metadata is available, consider new metadata, else if existing metadata is available consider it.
    int? ttl;
    ttl ??= newMetaData.ttl;
    if (ttl == null && existingMetaData != null) ttl = existingMetaData.ttl;

    int? ttb;
    ttb ??= newMetaData.ttb;
    if (ttb == null && existingMetaData != null) ttb = existingMetaData.ttb;

    int? ttr;
    ttr ??= newMetaData.ttr;
    if (ttr == null && existingMetaData != null) ttr = existingMetaData.ttr;

    bool? ccd;
    ccd ??= newMetaData.isCascade;
    if (ccd == null && existingMetaData != null) {
      ccd = existingMetaData.isCascade;
    }
    bool? isBinary;
    isBinary ??= newMetaData.isBinary;
    bool? isEncrypted;
    isEncrypted ??= newMetaData.isEncrypted;
    String? dataSignature;
    dataSignature ??= newMetaData.dataSignature;
    String? sharedKeyEncrypted;
    sharedKeyEncrypted ??= newMetaData.sharedKeyEnc;
    String? publicKeyChecksum;
    publicKeyChecksum ??= newMetaData.pubKeyCS;
    String? encoding;
    encoding ??= newMetaData.encoding;
    String? encKeyName;
    encKeyName ??= newMetaData.encKeyName;
    String? encAlgo;
    encAlgo ??= newMetaData.encAlgo;
    String? ivNonce;
    ivNonce ??= newMetaData.ivNonce;
    String? skeEncKeyName;
    skeEncKeyName ??= newMetaData.skeEncKeyName;

    String? skeEncAlgo;
    skeEncAlgo ??= newMetaData.skeEncAlgo;
    if (ttl != null && ttl >= 0) {
      setTTL(ttl, ttb: ttb);
    }
    if (ttb != null && ttb >= 0) {
      setTTB(ttb);
    }
    // If TTR is -1, cache the key forever.
    if (ttr != null && ttr > 0 || ttr == -1) {
      setTTR(ttr);
    }
    if (ccd != null) {
      setCCD(ccd);
    }
    atMetaData.isBinary = isBinary;
    atMetaData.isEncrypted = isEncrypted;
    atMetaData.dataSignature = dataSignature;
    atMetaData.sharedKeyEnc = sharedKeyEncrypted;
    atMetaData.pubKeyCS = publicKeyChecksum;
    atMetaData.encoding = encoding;
    atMetaData.encKeyName = encKeyName;
    atMetaData.encAlgo = encAlgo;
    atMetaData.ivNonce = ivNonce;
    atMetaData.skeEncKeyName = skeEncKeyName;
    atMetaData.skeEncAlgo = skeEncAlgo;
  }

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

  DateTime? _getAvailableAt(int epochNow, int ttb) {
    var availableAt = epochNow + ttb;
    return DateTime.fromMillisecondsSinceEpoch(availableAt).toUtc();
  }

  DateTime? _getExpiresAt(int epochNow, int ttl, {int? ttb}) {
    //if ttl is zero, reset expires at. The key will not expire
    if (ttl == 0) {
      return null;
    }
    var expiresAt = epochNow + ttl;
    if (ttb != null) {
      expiresAt = expiresAt + ttb;
    }
    return DateTime.fromMillisecondsSinceEpoch(expiresAt).toUtc();
  }

  DateTime? _getRefreshAt(DateTime today, int ttr) {
    if (ttr == -1) {
      return null;
    }

    return today.add(Duration(seconds: ttr));
  }

  AtMetaData build() {
    return atMetaData;
  }
}
