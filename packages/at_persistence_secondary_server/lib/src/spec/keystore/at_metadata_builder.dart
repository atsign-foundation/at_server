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

  /// Requires an AtMetaData.
  ///
  /// [asserted] carries caller-asserted timestamps (see
  /// [AtAssertedTimestamps]). An asserted value is stored faithfully:
  ///
  ///   * `createdAt`: asserted value wins — on creation and on update of an
  ///     existing record alike (the protocol treats a transmitted createdAt
  ///     as the record's true creation time, e.g. when a record moves
  ///     between atServers). Absent an assertion, a new record is stamped
  ///     now and an existing record keeps its stored value.
  ///   * `updatedAt`: asserted value wins; else stamped now.
  ///   * `expiresAt` / `availableAt`: an asserted value wins AT THIS WRITE,
  ///     suppressing the ttl/ttb derivation that would otherwise recompute
  ///     it from now — that derivation is exactly what a faithful transfer
  ///     must avoid, since it would restart the expiry clock on arrival.
  ///     A later write that supplies a ttl/ttb without an assertion
  ///     derives from now as usual. A caller that wants a write to leave
  ///     an expiry axis untouched carries the record's stored absolute
  ///     forward as an assertion — that is how the update verbs keep a
  ///     write that says nothing about expiry from restarting the expiry
  ///     clock.
  ///
  /// The inverse derivation also holds, on the caller's request: when
  /// [asserted] carries `deriveTtl`/`deriveTtb` (set by callers whose own
  /// request supplied the absolute without its relative), the ttl/ttb the
  /// asserted absolute implies is derived and stored, replacing whatever
  /// retained or coerced relative the write's metadata carries. See the
  /// derivation block in the constructor body for the formulas.
  AtMetadataBuilder({
    required String atSign,
    required AtMetaData? newAtMetaData,
    AtMetaData? existingMetaData,
    AtAssertedTimestamps? asserted,
  }) {
    atMetaData = newAtMetaData ?? existingMetaData ?? AtMetaData();
    // createdAt indicates the date and time of the key created.
    // For a new key, the currentDateTime is set and remains unchanged
    // on an update event — unless the caller asserts a createdAt.
    if (asserted?.createdAt != null) {
      atMetaData.createdAt = asserted!.createdAt;
    } else {
      (existingMetaData?.createdAt == null)
          ? atMetaData.createdAt = currentUtcTimeToMillisecondPrecision
          : atMetaData.createdAt = existingMetaData?.createdAt;
    }
    atMetaData.createdBy ??= atSign;
    atMetaData.updatedBy = atSign;
    // updatedAt indicates the date and time of the key updated.
    // For a new key, the updatedAt is same as createdAt and on key
    // update, set the updatedAt to the currentDateTime — unless the
    // caller asserts an updatedAt.
    atMetaData.updatedAt =
        asserted?.updatedAt ?? currentUtcTimeToMillisecondPrecision;
    atMetaData.status = 'active';
    // The version indicates the number of updates a key has received.
    // Version is set to 0 for a new key and for each update the key receives,
    // the version increases by 1
    (existingMetaData?.version == null)
        ? atMetaData.version = 0
        : atMetaData.version = (existingMetaData!.version! + 1);

    // Ensure that if there was existing metadata and it had immutable == true
    // then that value is preserved regardless of what the new update is trying
    // to do.
    //
    // No update or update:meta arrives here with an immutable record. Both
    // share AbstractUpdateVerbHandler.preProcess, which refuses one
    // outright ('Immutable records may not be updated'). That stays true for an
    // EXPIRED immutable record, but for the opposite reason: such a record is
    // deleted before the write, so this builder is handed existingMetaData ==
    // null and inherits nothing from it. The test 'A create over an EXPIRED
    // record inherits nothing from it', in at_secondary_server's
    // test/update_verb_test.dart, is what pins that.
    //
    // The guard is not dead code: the verb handlers are not the only writers.
    // The caching, enrollment, otp and config paths call keyStore.put/putMeta
    // directly, and that refusal is the only immutability check in the tree, so
    // none of them consults it. This is the backstop for those — which is why
    // the warning below logs what it was asked to do.
    if (existingMetaData?.immutable == true) {
      if (newAtMetaData?.immutable != true) {
        logger.warning('Existing metadata.immutable is true,'
            ' but new metadata.immutable is ${newAtMetaData?.immutable}'
            ' : will preserve immutable == true'
            ' : logging stack trace for reference');
        logger.warning(StackTrace.current);
      }
      atMetaData.immutable = true;
    }

    // set expiresAt based on the ttl — an asserted expiresAt wins over
    // the derivation at this write (the write's ttl, if any, is still
    // stored unless the caller asked for a derivation below)
    if (asserted?.expiresAt != null) {
      atMetaData.expiresAt = asserted!.expiresAt;
    } else if (atMetaData.ttl != null && atMetaData.ttl! >= 0) {
      // The ttb offset (forward: expiresAt = now + ttb + ttl, a record
      // lives ttl ms from when it becomes available) applies only when
      // this same write is re-deriving the birth window too. When an
      // asserted availableAt pins the birth (a caller assertion, or the
      // update verbs' expiry-silent carry), folding the metadata's ttb in
      // would stretch the lifetime by a birth delay that is not
      // restarting: a ttl-only write on a born record must expire at
      // now + ttl exactly.
      setTTL(atMetaData.ttl,
          ttb: asserted?.availableAt == null ? atMetaData.ttb : null);
    }
    // set availableAt based on the ttb — same assertion-wins rule
    if (asserted?.availableAt != null) {
      atMetaData.availableAt = asserted!.availableAt;
    } else if (atMetaData.ttb != null && atMetaData.ttb! >= 0) {
      setTTB(atMetaData.ttb);
    }

    // A record stored with an asserted absolute also carries the relative
    // it implies — when the caller ASKED for that, via deriveTtb/deriveTtl
    // (set when the caller's own request supplied the absolute without the
    // relative; only the caller can tell, because a caller-supplied ttl
    // and one retained from the stored record or coerced from an absent
    // field are indistinguishable here). The derivation happens once, at
    // this write; reads return the stored values verbatim and never
    // recompute. It REPLACES whatever ttl/ttb the write's metadata
    // carries — that value is retained or coerced, not the caller's. The
    // formulas invert setTTB/setTTL's forward derivations, computed from
    // the ASSERTED absolutes only (never from an availableAt that
    // setTTB(0) manufactured from this server's clock three lines up):
    // ttb spans updatedAt→availableAt, and ttl spans birth→expiresAt,
    // where birth is the asserted availableAt when that lies ahead of
    // updatedAt. Measuring from the stored updatedAt rather than this
    // server's clock makes the result reproducible: a faithful transfer
    // asserting uAt derives the same ttl on every server. A non-positive
    // result clears the relative instead (null, never 0 — ttl 0 would
    // mean "never expires"): the record is simply already available /
    // already expired, and a retained relative would contradict the
    // asserted absolute.
    if (asserted != null) {
      final updatedAt = atMetaData.updatedAt!;
      if (asserted.deriveTtb && asserted.availableAt != null) {
        final ttb =
            asserted.availableAt!.difference(updatedAt).inMilliseconds;
        atMetaData.ttb = ttb > 0 ? ttb : null;
      }
      if (asserted.deriveTtl && asserted.expiresAt != null) {
        final assertedAvailableAt = asserted.availableAt;
        final birth = (assertedAvailableAt != null &&
                assertedAvailableAt.isAfter(updatedAt))
            ? assertedAvailableAt
            : updatedAt;
        final ttl = asserted.expiresAt!.difference(birth).inMilliseconds;
        atMetaData.ttl = ttl > 0 ? ttl : null;
      }
    }

    // Set refreshAt based on the TTR
    if (atMetaData.ttr != null && atMetaData.ttr! > 0 || atMetaData.ttr == -1) {
      setTTR(atMetaData.ttr);
    }
  }

  void setTTL(int? ttl, {int? ttb}) {
    if (ttl != null) {
      atMetaData.ttl = ttl;
      atMetaData.expiresAt = _getExpiresAt(
          currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttl,
          ttb: ttb);
    } else {
      atMetaData.expiresAt = null;
    }
  }

  void setTTB(int? ttb) {
    if (ttb != null) {
      atMetaData.ttb = ttb;
      atMetaData.availableAt = _getAvailableAt(
          currentUtcTimeToMillisecondPrecision.millisecondsSinceEpoch, ttb);
      logger
          .finer('setTTB($ttb) - set availableAt to ${atMetaData.availableAt}');
    } else {
      atMetaData.availableAt = null;
    }
  }

  void setTTR(int? ttr) {
    if (ttr != null) {
      atMetaData.ttr = ttr;
      atMetaData.refreshAt =
          _getRefreshAt(currentUtcTimeToMillisecondPrecision, ttr);
    } else {
      atMetaData.refreshAt = null;
    }
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
