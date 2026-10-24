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

  final Queue<_Queued> _queued = Queue<_Queued>();
  int _queuedDuringReplay = 0;
  bool _draining = false;
  Completer<void>? _idle;
  int _droppedOnClose = 0;
  bool _closed = false;

  @override
  final InboundConnection connection;

  @override
  Future<void> get idle {
    if (_isIdle) {
      return Future<void>.value();
    }
    return (_idle ??= Completer<void>()).future;
  }

  @override
  void push(AtNotification n, {LivePushReport? report}) {
    if (_closed || !_takesType(n)) {
      return;
    }
    final bool duringReplay = !_opened.isCompleted;
    if (duringReplay) {
      _queuedDuringReplay++;
    }
    _queued.add((
      n: n,
      duringReplay: duringReplay,
      report: report,
      slot: report?.expect() ?? -1,
    ));
    _drainSoon();
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
      _release();
    }
  }

  @override
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _release();
  }

  /// Releases the live pushes queued behind the replay, once.
  void _release() {
    if (_opened.isCompleted) {
      return;
    }
    _opened.complete();
    if (_queuedDuringReplay == 0) {
      _replayed.clear();
    }
    _drainSoon();
    _settleIdle();
  }

  bool get _isIdle => _opened.isCompleted && !_draining && _queued.isEmpty;

  void _settleIdle() {
    if (!_isIdle) {
      return;
    }
    final Completer<void>? idle = _idle;
    _idle = null;
    idle?.complete();
  }

  // NOTE drained from a microtask, so the regex runs in this feed's own turn
  // rather than inside the call that queued the notification.
  void _drainSoon() {
    if (_draining || !_opened.isCompleted || _queued.isEmpty) {
      return;
    }
    _draining = true;
    scheduleMicrotask(() => unawaited(_drain()));
  }

  /// Settles the queued notifications one at a time, in order.
  Future<void> _drain() async {
    try {
      while (_queued.isNotEmpty) {
        final _Queued q = _queued.removeFirst();
        LivePush? written;
        try {
          if (_wanted(q)) {
            written = await _write(q.n);
          }
        } catch (e, st) {
          _handler.logger.severe('Unexpected exception $e while pushing'
              ' notification ${q.n.id} to ${_describeConnection()}\n$st');
        }
        if (q.duringReplay && --_queuedDuringReplay == 0) {
          _replayed.clear();
        }
        q.report?.settle(q.slot, written);
      }
    } finally {
      _draining = false;
      if (_closed && _droppedOnClose > 0) {
        _handler.logger.warning('Dropped $_droppedOnClose queued'
            ' notification${_droppedOnClose == 1 ? '' : 's'} for'
            ' ${_describeConnection()}: its monitor feed has ended');
        _droppedOnClose = 0;
      }
      _settleIdle();
    }
  }

  /// Whether [q] is one this feed writes, counting it as dropped instead
  /// once the feed has ended.
  bool _wanted(_Queued q) {
    if (!_takes(q.n) ||
        (q.duringReplay && _replayed.contains((q.n.fromAtSign, q.n.id)))) {
      return false;
    }
    if (_closed) {
      _droppedOnClose++;
      return false;
    }
    return true;
  }

  bool _takesType(AtNotification n) =>
      n.type == NotificationType.received ||
      (_withSelf && n.type == NotificationType.self);

  bool _takes(AtNotification n) =>
      _takesType(n) &&
      ((n.notification?.contains(_regex) ?? false) ||
          (n.fromAtSign?.replaceAll('@', '').contains(_regex) ?? false));

  /// Writes [n] if the connection may have it, returning the push, or null
  /// after logging why it was not written.
  Future<LivePush?> _write(AtNotification n) async {
    final InboundConnectionMetadata metaData =
        connection.metaData as InboundConnectionMetadata;
    if (_closed || connection.isInValid()) {
      _dropped(n, _invalidReason);
      return null;
    }
    if (n.isExpired()) {
      _dropped(n, 'it has expired');
      return null;
    }
    LivePush push;
    do {
      if (!metaData.isAuthenticated) {
        _dropped(n, 'the connection is not authenticated');
        return null;
      }
      // NOTE read in the same step as isAuthorized reads them, so the push is
      // reported as the enrollment that authorized it.
      push = (enrollmentId: metaData.enrollmentId, authType: metaData.authType);
      final bool authorized;
      try {
        authorized =
            await _handler.isAuthorized(metaData, atKey: n.notification);
      } catch (e) {
        _handler.logger.severe('$e while looking up the enrollment for'
            ' notification ${n.id}'
            ' (${sanitiseForLogging(n.notification ?? '')}) to'
            ' ${_describeConnection()}');
        return null;
      }
      if (!authorized) {
        _dropped(n, 'not authorized for that key');
        return null;
      }
      if (_closed || connection.isInValid()) {
        _dropped(n, _invalidReason);
        return null;
      }
      // NOTE authorized again whenever the connection re-authenticated
      // during the lookup: a push is written only for the enrollment the
      // connection stands on when it is written.
    } while (!metaData.isAuthenticated ||
        metaData.enrollmentId != push.enrollmentId ||
        metaData.authType != push.authType);
    try {
      await connection.write('notification: ${jsonEncode(n.mapForClient)}\n');
      return push;
    } catch (e) {
      _handler.logger.severe('$e while delivering notification ${n.id}'
          ' to ${_describeConnection()}');
      return null;
    }
  }

  String get _invalidReason => _closed || connection.metaData.isClosed
      ? 'the connection is closed'
      : 'the connection is idle or stale';

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

/// A notification queued on a feed, with the report slot it settles.
typedef _Queued = ({
  AtNotification n,
  bool duringReplay,
  LivePushReport? report,
  int slot,
});

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
