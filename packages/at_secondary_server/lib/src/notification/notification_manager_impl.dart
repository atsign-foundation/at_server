import 'dart:async';
import 'dart:math' show min;

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notify_connection_pool.dart';
import 'package:at_utils/at_utils.dart' show AtSignLogger;
import 'package:meta/meta.dart';

class NotificationManager {
  final Atsign atSign;

  final AtNotificationKeystore _notifStore;

  @visibleForTesting
  AtNotificationKeystore get notifStore => _notifStore;

  final NotifyConnectionsPool _notifyConnectionsPool;

  @visibleForTesting
  NotifyConnectionsPool get notifyConnectionsPool => _notifyConnectionsPool;

  final AtSignLogger logger = AtSignLogger(' NotificationManager ')
    ..level = 'info';

  bool _closed = false;

  bool get closed => _closed;

  @visibleForTesting
  Map<Atsign, PerAtSignNotifSender> senders = {};

  final StreamController<AtNotification> received =
      StreamController.broadcast();
  final StreamController<AtNotification> self = StreamController.broadcast();
  @visibleForTesting
  final StreamController<AtNotification> sent = StreamController.broadcast();

  NotificationManager(
      this.atSign, this._notifStore, this._notifyConnectionsPool);

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    for (final s in senders.values) {
      await s.close();
    }

    await received.close();
    await self.close();
    await sent.close();
  }

  /// Enqueue notification to send to either another atSign, or ourselves
  ///
  /// Note that this does not persist the notification
  void enqueue(AtNotification n) {
    if (closed) {
      throw StateError('Closed');
    }

    logger.info('enqueue ${n.id} (${n.notification})');
    switch (n.type) {
      case NotificationType.sent:
        if (n.toAtSign?.toAtsign() == atSign) {
          String s = 'notificationType "sent" but toAtsign ${n.toAtSign}'
              ' is the same as our atSign $atSign';
          logger.severe(s);
          throw StateError(s);
        }
        if (n.fromAtSign != atSign) {
          String s = 'notificationType "sent" but fromAtsign ${n.fromAtSign}'
              ' is not the same as our atSign $atSign';
          logger.severe(s);
          throw StateError(s);
        }
        sent.add(n); // Useful for testing only
        // We are sending this notification to another atSign
        getPerAtSignNotifSender(n.toAtSign!.toAtsign()).notifs.add(n);
        break;

      case NotificationType.received:
        // We have received from another atSign
        received.add(n);
        break;
      case NotificationType.self:
        if ((n.toAtSign ?? atSign) != atSign) {
          String s = 'notificationType "self" but toAtsign ${n.toAtSign}'
              ' is not our atSign $atSign';
          logger.severe(s);
          throw StateError(s);
        }
        // We are sending this notification to ourselves (other clients)
        self.add(n);
        break;
      case null:
        throw InvalidSyntaxException('Notification type is required');
    }
  }

  /// Persists the notification and calls [enqueue]
  Future<void> notify(AtNotification n) async {
    if (closed) {
      throw StateError('Closed');
    }

    // Persist the notification
    await _notifStore.put(n.id, n);

    // Queue it for delivery
    enqueue(n);
  }

  Future<List<AtNotification>> getUndelivered() async {
    return await getFilteredSorted(
      retain: (n) {
        // Retain where
        //   Not expired &&
        //   NotificationType == sent &&
        //   NotificationStatus == queued
        // SORT them by the time they were created
        return !n.isExpired() &&
            n.type == NotificationType.sent &&
            n.notificationStatus == NotificationStatus.queued;
      },
      comparator: compareDateTime,
    );
  }

  Future<void> reEnqueueUndelivered() async {
    for (final n in await getUndelivered()) {
      try {
        enqueue(n);
      } catch (e) {
        logger.severe('Unable to enqueue notification: $e');
        logger.severe('Notification details: ${n.toJson().toString()}');
      }
    }
  }

  @visibleForTesting
  PerAtSignNotifSender getPerAtSignNotifSender(Atsign atSign) {
    if (!senders.containsKey(atSign)) {
      senders[atSign] = PerAtSignNotifSender(atSign, this);
    }
    return senders[atSign]!;
  }

  Future<dynamic> put(key, value) {
    return _notifStore.put(key, value);
  }

  Future<void> remove(String notificationId) {
    return _notifStore.remove(notificationId);
  }

  Future<bool> isKeyExists(String key) async {
    return _notifStore.isKeyExists(key);
  }

  Future<AtNotification?> get(key) {
    return _notifStore.get(key);
  }

  Future<List> getKeys({String? regex}) async {
    return _notifStore.getKeys(regex: regex);
  }

  int compareDateTime(AtNotification n1, AtNotification n2) {
    if (n1.notificationDateTime == null && n2.notificationDateTime == null) {
      return 0;
    }
    if (n1.notificationDateTime == null) {
      return -1;
    }
    if (n2.notificationDateTime == null) {
      return 1;
    }

    return n1.notificationDateTime!.compareTo(n2.notificationDateTime!);
  }

  /// Return a list of unexpired notifications
  /// - where [retain] returns true
  /// - sorted by the [comparator] if provided.
  ///
  /// Note the [compareDateTime] comparator which is provided in this class
  /// for convenience.
  Future<List<AtNotification>> getFilteredSorted({
    required bool Function(AtNotification) retain,
    required int Function(AtNotification, AtNotification)? comparator,
  }) async {
    List<AtNotification> values = [];

    // Iterate through all the keys
    for (final k in _notifStore.getKeys()) {
      //   Fetch each one in turn
      AtNotification? n = await _notifStore.get(k);
      //   Filter null (who knows)
      if (n == null) {
        continue;
      }

      if (retain(n)) {
        //   Add to list
        values.add(n);
      }
    }

    if (comparator != null) {
      // Sort the list using the provided comparator, if provided
      values.sort(comparator);
    }

    return values;
  }

  int defaultTtlnMillis = 15 * 60 * 1000; // 15 mins
  @visibleForTesting
  String prepareNotifyCommandBody(AtNotification atNotification) {
    // [gkc] I really don't like that the command string is being built from
    // the end backwards to the start; it has confused me every time I've
    // looked at this code.
    String commandBody;
    commandBody = '${atNotification.notification}';
    if (atNotification.atValue != null) {
      commandBody = '$commandBody:${atNotification.atValue}';
    }
    var atMetaData = atNotification.atMetadata;
    if (atMetaData != null) {
      if (atNotification.atMetadata!.immutable == true) {
        commandBody = '${AtConstants.immutable}:true:$commandBody';
      }
      if (atNotification.atMetadata!.skeEncAlgo != null) {
        commandBody =
            '${AtConstants.sharedKeyEncryptedEncryptingAlgo}:${atNotification.atMetadata!.skeEncAlgo}:$commandBody';
      }
      if (atNotification.atMetadata!.skeEncKeyName != null) {
        commandBody =
            '${AtConstants.sharedKeyEncryptedEncryptingKeyName}:${atNotification.atMetadata!.skeEncKeyName}:$commandBody';
      }
      if (atNotification.atMetadata!.ivNonce != null) {
        commandBody =
            '${AtConstants.ivOrNonce}:${atNotification.atMetadata!.ivNonce}:$commandBody';
      }
      if (atNotification.atMetadata!.encAlgo != null) {
        commandBody =
            '${AtConstants.encryptingAlgo}:${atNotification.atMetadata!.encAlgo}:$commandBody';
      }
      if (atNotification.atMetadata!.encKeyName != null) {
        commandBody =
            '${AtConstants.encryptingKeyName}:${atNotification.atMetadata!.encKeyName}:$commandBody';
      }
      if (atNotification.atMetadata!.pubKeyHash != null) {
        commandBody =
            '${AtConstants.sharedWithPublicKeyHash}:${atNotification.atMetadata!.pubKeyHash?.hash}:${AtConstants.sharedWithPublicKeyHashingAlgo}:${atNotification.atMetadata!.pubKeyHash?.hashingAlgo}:$commandBody';
      }
      if (atNotification.atMetadata!.pubKeyCS != null) {
        commandBody =
            '${AtConstants.sharedWithPublicKeyCheckSum}:${atNotification.atMetadata!.pubKeyCS}:$commandBody';
      }
      if (atNotification.atMetadata!.sharedKeyEnc != null) {
        commandBody =
            '${AtConstants.sharedKeyEncrypted}:${atNotification.atMetadata!.sharedKeyEnc}:$commandBody';
      }

      String? isEncryptedStr =
          (atNotification.atMetadata!.isEncrypted ?? false) ? 'true' : 'false';
      commandBody = '${AtConstants.isEncrypted}:$isEncryptedStr:$commandBody';

      if (atMetaData.ttr != null) {
        commandBody =
            'ttr:${atMetaData.ttr}:ccd:${atMetaData.isCascade}:$commandBody';
      }
      if (atMetaData.ttb != null) {
        commandBody = 'ttb:${atMetaData.ttb}:$commandBody';
      }
      if (atMetaData.ttl != null) {
        commandBody = 'ttl:${atMetaData.ttl}:$commandBody';
      }
    }
    if (atNotification.ttl == null) {
      logger.warning('ttln on ${atNotification.id} is null');
      commandBody = 'ttln:$defaultTtlnMillis:$commandBody';
    } else {
      // ttln is not null
      if (atNotification.expiresAt == null) {
        // should never happen
        logger.warning('expiresAt on ${atNotification.id} is null');
        commandBody = 'ttln:$defaultTtlnMillis:$commandBody';
      } else {
        // expiresAt has a valid value
        // set ttln in the issued command based on the difference between
        // now and expiresAt, so we approximately preserve expiresAt on the
        // receiving side
        //       expiresAt = DateTime.now()
        //           .toUtcMillisecondsPrecision()
        //           .add(Duration(milliseconds: ttl!));
        int ttln = atNotification.expiresAt!.millisecondsSinceEpoch -
            DateTime.now().millisecondsSinceEpoch;
        // If we've somehow already passed the expiresAt, then set it 1 ms
        if (ttln <= 0) {
          ttln = 1;
        }
        commandBody = 'ttln:$ttln:$commandBody';
      }
    }

    commandBody = 'notifier:${atNotification.notifier}:$commandBody';
    commandBody =
        'messageType:${atNotification.messageType.toString().split('.').last}:$commandBody';
    if (atNotification.opType != null) {
      commandBody =
          '${atNotification.opType.toString().split('.').last}:$commandBody';
    }
    // prepending id to the notify command.
    commandBody = 'id:${atNotification.id!}:$commandBody';
    return commandBody;
  }
}

class PerAtSignNotifSender {
  @visibleForTesting
  static Duration initialDelay = const Duration(milliseconds: 200);
  @visibleForTesting
  static Duration maxDelay = const Duration(seconds: 10);
  static final phi = 1.618034;

  final Atsign atSign;
  final NotificationManager notifMgr;
  final StreamController<AtNotification> notifs = StreamController();
  late final AtSignLogger logger;
  late final StreamSubscription<AtNotification> sub;

  PerAtSignNotifSender(this.atSign, this.notifMgr) {
    logger = AtSignLogger(' PerAtSignNotifSender ($atSign) ')..level = 'info';
    sub = notifs.stream.listen(onNotif, onDone: () => logger.info('Done'));
    logger.info('Listening');
  }

  Future<void> onNotif(AtNotification n) async {
    sub.pause(); // we want to handle one at a time

    try {
      await send(n);
    } catch (e, st) {
      logger.severe('send(notif) threw unexpected exception $e\n$st');
    } finally {
      sub.resume();
    }
  }

  @visibleForTesting
  Future<void> send(AtNotification n) async {
    logger.info('send: ${n.id} (${n.notification})');

    if (n.toAtSign?.toAtsign() != atSign) {
      logger.severe('toAtsign is ${n.toAtSign} but we are for $atSign');
      return;
    }

    if (n.notificationStatus != NotificationStatus.queued) {
      logger.severe('need status queued but got ${n.notificationStatus}');
      return;
    }

    // We keep trying until either
    // (1) successful delivery, or
    // (2) atSign no longer in directory
    Duration delay = initialDelay;
    while (true) {
      try {
        // not much point in sending expired notifications, is there
        if (n.isExpired()) {
          logger.info('notification ${n.id} has expired - will not deliver');
          n.notificationStatus = NotificationStatus.expired;
          try {
            await notifMgr.put(n.id, n);
          } catch (e) {
            logger.warning(
                'Exception $e while setting status expired on ${n.id}');
          }
          return;
        }

        //   get outbound client and send notify command
        var outBoundClient =
            await notifMgr.notifyConnectionsPool.getOutboundClient(atSign);
        var notifyCommandBody = notifMgr.prepareNotifyCommandBody(n);
        var notifyResponse = await outBoundClient.notify(notifyCommandBody);
        // if response was data:success - great, we're done!
        if (notifyResponse == 'data:success') {
          n.notificationStatus = NotificationStatus.delivered;
          logger.info('Delivered ${n.id} (${n.notification})');
          try {
            await notifMgr.put(n.id, n);
          } catch (e) {
            logger.warning(
                'Exception $e while setting status delivered on ${n.id}');
          }
          return;
        } else {
          throw Exception('Unexpected response $notifyResponse');
        }
      } catch (e) {
        try {
          await notifMgr.notifyConnectionsPool.secondaryAddressFinder
              .findSecondary(atSign);
        } on SecondaryNotFoundException catch (_) {
          logger.warning('no such atSign $atSign - giving up on ${n.id}');
          n.notificationStatus = NotificationStatus.errored;
          await notifMgr.put(n.id, n);
          return;
        }
        logger.info('Error while sending ${n.id}: ${e.runtimeType} : $e\n');
        logger.info('Will retry in $delay');
        await Future.delayed(delay);
        if (delay < maxDelay) {
          delay = Duration(
              milliseconds: min((delay.inMilliseconds * phi).floor(),
                  maxDelay.inMilliseconds));
        }
      }
    }
  }

  Future<void> close() async {
    await sub.cancel();
    await notifs.close();
  }
}
