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

  /// Requires an AtMetaData
  AtMetadataBuilder(
      {
      String? atSign,
      required AtMetaData? newAtMetaData,
      AtMetaData? existingMetaData,
      }) {
    atMetaData = newAtMetaData ?? AtMetaData();
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

    // Checks on existing important metadata
    if (existingMetaData != null) {
      atMetaData.ttl ??= existingMetaData.ttl;

      atMetaData.ttb ??= existingMetaData.ttb;

      atMetaData.ttr ??= existingMetaData.ttr;

      atMetaData.isCascade ??= existingMetaData.isCascade;

      // special handling for immutable
      if (existingMetaData.immutable == true) {
        atMetaData.immutable = true;
      }
    }

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
    if (atMetaData.isCascade != null) {
      setCCD(atMetaData.isCascade!);
    }
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
