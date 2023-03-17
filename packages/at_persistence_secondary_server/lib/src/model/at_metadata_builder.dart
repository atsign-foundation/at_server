import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// Builder class to build [AtMetaData] object.
class AtMetadataBuilder {
  late AtMetaData atMetaData;
  /// We will constrain to millisecond precision because Hive only stores
  /// [DateTime]s to millisecond precision - see https://github.com/hivedb/hive/issues/474
  /// for details.
  var currentUtcTimeToMillisecondPrecision = DateTime.now().toUtcMillisecondsPrecision();

  /// AtMetadata Object : Optional parameter, If atMetadata object is null a new AtMetadata object is created.
  /// ttl : Time to live of the key. If ttl is null, atMetadata's ttl is assigned to ttl.
  /// ttb : Time to birth of the key. If ttb is null, atMetadata's ttb is assigned to ttb.
  /// ttr : Time to refresh of the key. If ttr is null, atMetadata's ttr is assigned to ttr.
  /// ccd : Cascade delete. If ccd is null, atMetadata's ccd is assigned to ccd.
  AtMetadataBuilder(
      {String? atSign,
      AtMetaData? newAtMetaData,
      AtMetaData? existingMetaData,
      int? ttl,
      int? ttb,
      int? ttr,
      bool? ccd,
      bool? isBinary,
      bool? isEncrypted,
      String? dataSignature,
      String? sharedKeyEncrypted,
      String? publicKeyChecksum,
      String? encoding,
      String? encKeyName,
      String? encAlgo,
      String? ivNonce,
      String? skeEncKeyName,
      String? skeEncAlgo,
      }) {
    newAtMetaData ??= AtMetaData();
    atMetaData = newAtMetaData;
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
    // The version indicates the number of updates a key has received.
    // Version is set to 0 for a new key and for each update the key receives,
    // the version increases by 1
    (existingMetaData?.version == null)
        ? atMetaData.version = 0
        : atMetaData.version = (existingMetaData!.version! + 1);

    //If new metadata is available, consider new metadata, else if existing metadata is available consider it.
    ttl ??= newAtMetaData.ttl;
    if (ttl == null && existingMetaData != null) ttl = existingMetaData.ttl;

    ttb ??= newAtMetaData.ttb;
    if (ttb == null && existingMetaData != null) ttb = existingMetaData.ttb;

    ttr ??= newAtMetaData.ttr;
    if (ttr == null && existingMetaData != null) ttr = existingMetaData.ttr;

    ccd ??= newAtMetaData.isCascade;
    if (ccd == null && existingMetaData != null) {
      ccd = existingMetaData.isCascade;
    }
    isBinary ??= newAtMetaData.isBinary;
    isEncrypted ??= newAtMetaData.isEncrypted;
    dataSignature ??= newAtMetaData.dataSignature;
    sharedKeyEncrypted ??= newAtMetaData.sharedKeyEnc;
    publicKeyChecksum ??= newAtMetaData.pubKeyCS;
    encoding ??= newAtMetaData.encoding;
    encKeyName ??= newAtMetaData.encKeyName;
    encAlgo ??= newAtMetaData.encAlgo;
    ivNonce ??= newAtMetaData.ivNonce;
    skeEncKeyName ??= newAtMetaData.skeEncKeyName;
    skeEncAlgo ??= newAtMetaData.skeEncAlgo;

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
      atMetaData.expiresAt =
          _getExpiresAt(currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttl, ttb: ttb);
    }
  }

  void setTTB(int? ttb) {
    if (ttb != null) {
      atMetaData.ttb = ttb;
      atMetaData.availableAt =
          _getAvailableAt(currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttb);
    }
  }

  void setTTR(int? ttr) {
    if (ttr != null) {
      atMetaData.ttr = ttr;
      atMetaData.refreshAt = _getRefreshAt(currentUtcTimeToMillisecondPrecision, ttr);
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
