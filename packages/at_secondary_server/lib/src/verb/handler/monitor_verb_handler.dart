import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/connection/inbound/inbound_write_queue.dart';
import 'package:at_secondary/src/notification/monitor_sink.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

/// Handles `monitor`: gives the connection one feed of live notifications,
/// replacing any feed it had, after writing the stored ones an epoch asks
/// for.
class MonitorVerbHandler extends AbstractVerbHandler {
  static Monitor monitor = Monitor();

  MonitorVerbHandler(super.keyStore, this.notifMgr);

  NotificationManager notifMgr;

  @override
  bool accept(String command) => command.startsWith(getName(VerbEnum.monitor));

  @override
  Verb getVerb() {
    return monitor;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    if (!atConnection.metaData.isAuthenticated) {
      throw UnAuthenticatedException(
          'Failed to execute verb. monitor requires authentication');
    }
    // If regex is not provided by user, set regex to ".*" to match all the possibilities
    // else set regex to the value given by the user.
    final RegExp regex;
    try {
      regex = RegExp(verbParams[AtConstants.regex] ?? '.*');
    } catch (e) {
      throw InvalidSyntaxException(
          'Invalid regex: ${verbParams[AtConstants.regex]}');
    }
    final String? epoch = verbParams[AtConstants.epochMilliseconds];
    final int? sinceMillis = epoch == null ? null : int.parse(epoch);

    final _MonitorFeed feed = _MonitorFeed(this, atConnection, regex,
        withSelf: verbParams[AtConstants.monitorSelfNotifications] ==
            AtConstants.monitorSelfNotifications);
    final MonitorSink? previous = notifMgr.addMonitor(feed);
    final AtConnectionMetaData metaData = atConnection.metaData;
    if (previous == null && metaData is InboundConnectionMetadata) {
      unawaited(
          metaData.closed.then((_) => notifMgr.removeMonitor(atConnection)));
    }
    try {
      final List<AtNotification> backlog = sinceMillis == null
          ? const <AtNotification>[]
          : await notifMgr.getFilteredSorted(
              retain: (AtNotification n) => feed.replays(n, sinceMillis),
              comparator: notifMgr.compareDateTime);
      await feed.open(backlog, after: previous?.idle);
    } catch (_) {
      notifMgr.removeMonitor(atConnection, only: feed);
      rethrow;
    }
    atConnection.isMonitor = true;
  }
}

/// A connection's feed of live notifications, written one at a time in the
/// order they were queued, each authorized for the enrollment the
/// connection stands on when it is written.
class _MonitorFeed implements MonitorSink {
  _MonitorFeed(this._handler, this.connection, this._regex,
      {required bool withSelf})
      : _withSelf = withSelf;

  final MonitorVerbHandler _handler;
  final RegExp _regex;
  final bool _withSelf;

  /// Completes when the replay is done, releasing the live pushes.
  final Completer<void> _opened = Completer<void>();

  /// The sender and id of each notification the replay wrote, consulted only
  /// by pushes queued during the replay.
  final Set<(String?, String?)> _replayed = <(String?, String?)>{};

  late Future<void> _tail = _opened.future;
  int _queued = 0;
  bool _closed = false;

  @override
  final InboundConnection connection;

  @override
  Future<void> get idle => _tail;

  @override
  Future<LivePush?> push(AtNotification n) {
    if (_closed) {
      return Future<LivePush?>.value(null);
    }
    final bool duringReplay = !_opened.isCompleted;
    _queued++;
    final Future<LivePush?> written = _tail
        .then((_) => _deliver(n, duringReplay))
        .whenComplete(() => _queued--);
    _tail = written;
    return written;
  }

  /// Whether `monitor:<sinceMillis>` replays [n] to this feed. Replay
  /// matches the key alone; live delivery also matches the sender.
  bool replays(AtNotification n, int sinceMillis) =>
      !n.isExpired() &&
      (n.notificationDateTime?.millisecondsSinceEpoch ?? 0) > sinceMillis &&
      _takesType(n) &&
      (n.notification?.contains(_regex) ?? false);

  /// Writes [backlog] once [after] has settled, then releases the live
  /// pushes queued behind it. Each stored notification waits until the
  /// connection has nothing waiting to be sent.
  Future<void> open(List<AtNotification> backlog, {Future<void>? after}) async {
    final InboundConnection connection = this.connection;
    try {
      await after;
      for (final AtNotification n in backlog) {
        if (connection case final DrainableConnection drainable) {
          await drainable.drained;
        }
        if (_closed || connection.isInValid()) {
          break;
        }
        if (await _write(n) != null) {
          _replayed.add((n.fromAtSign, n.id));
        }
      }
    } finally {
      final Future<void> queuedDuringReplay = _tail;
      if (!_opened.isCompleted) {
        _opened.complete();
      }
      unawaited(queuedDuringReplay.then((_) => _replayed.clear()));
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_queued > 0) {
      _handler.logger.warning('Dropping $_queued notifications queued for'
          ' ${_describeConnection()}: its monitor feed has ended');
    }
    if (!_opened.isCompleted) {
      _opened.complete();
    }
  }

  bool _takesType(AtNotification n) =>
      n.type == NotificationType.received ||
      (_withSelf && n.type == NotificationType.self);

  bool _takes(AtNotification n) =>
      _takesType(n) &&
      ((n.notification?.contains(_regex) ?? false) ||
          (n.fromAtSign?.replaceAll('@', '').contains(_regex) ?? false));

  Future<LivePush?> _deliver(AtNotification n, bool duringReplay) async {
    try {
      if (_closed || !_takes(n)) {
        return null;
      }
      if (duringReplay && _replayed.contains((n.fromAtSign, n.id))) {
        return null;
      }
      return await _write(n);
    } catch (e, st) {
      _handler.logger.severe('Unexpected exception $e while pushing'
          ' notification ${n.id} to ${_describeConnection()}\n$st');
      return null;
    }
  }

  /// Writes [n] if the connection may have it, returning the push, or null
  /// after logging why it was not written.
  Future<LivePush?> _write(AtNotification n) async {
    final InboundConnectionMetadata metaData =
        connection.metaData as InboundConnectionMetadata;
    if (_closed || connection.isInValid()) {
      _dropped(n, 'the connection is closed');
      return null;
    }
    if (n.isExpired()) {
      _dropped(n, 'it has expired');
      return null;
    }
    if (!metaData.isAuthenticated) {
      _dropped(n, 'the connection is not authenticated');
      return null;
    }
    // NOTE read in the same step as isAuthorized reads them, so the push is
    // reported as the enrollment that authorized it.
    final LivePush push =
        (enrollmentId: metaData.enrollmentId, authType: metaData.authType);
    if (!await _handler.isAuthorized(metaData, atKey: n.notification)) {
      _dropped(n, 'not authorized for that key');
      return null;
    }
    try {
      await connection.write('notification: ${jsonEncode(n.mapForClient)}\n');
      return push;
    } catch (e) {
      _handler.logger.severe('$e while delivering notification ${n.id}'
          ' to ${_describeConnection()}');
      return null;
    }
  }

  void _dropped(AtNotification n, String why) {
    // NOTE at warning: a dropped push is otherwise indistinguishable from one
    // that was never sent.
    _handler.logger.warning('Not delivering notification ${n.id}'
        ' (${sanitiseForLogging(n.notification ?? '')}) to'
        ' ${_describeConnection()}: $why');
  }

  String _describeConnection() => describeInboundConnection(
      connection.metaData as InboundConnectionMetadata);
}

extension MapForClient on AtNotification {
  Map<String, dynamic> get mapForClient => {
        AtConstants.id: id,
        AtConstants.from: fromAtSign,
        AtConstants.to: toAtSign,
        AtConstants.key: notification,
        AtConstants.value: atValue,
        AtConstants.operation: opType?.name,
        AtConstants.epochMilliseconds:
            notificationDateTime!.millisecondsSinceEpoch,
        AtConstants.messageType: messageType?.toString(),
        AtConstants.isEncrypted: atMetadata?.isEncrypted ?? false,
        "metadata": {
          "ttr": atMetadata?.ttr,
          "ttl": atMetadata?.ttl,
          "ttb": atMetadata?.ttb,
          "sharedKeyEnc": atMetadata?.sharedKeyEnc,
          "pubKeyCS": atMetadata?.pubKeyCS,
          "dataSignature": atMetadata?.dataSignature,
          "encKeyName": atMetadata?.encKeyName,
          "encAlgo": atMetadata?.encAlgo,
          "ivNonce": atMetadata?.ivNonce,
          "skeEncKeyName": atMetadata?.skeEncKeyName,
          "skeEncAlgo": atMetadata?.skeEncAlgo,
          "availableAt": atMetadata?.availableAt.toString(),
          "expiresAt": (atMetadata?.expiresAt ?? expiresAt).toString(),
          "pubKeyHash": atMetadata?.pubKeyHash != null
              ? jsonEncode(atMetadata?.pubKeyHash?.toJson())
              : null,
          // The client parses this with Metadata.decodeAppMetadata,
          // which accepts a Map (emitted here) or a base64 string.
          AtConstants.appMetadata: atMetadata?.appMetadata?.toJson(),
        }
      };
}
