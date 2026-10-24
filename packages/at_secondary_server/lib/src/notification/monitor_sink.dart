import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// A live push written to a monitor connection, with the enrollment and the
/// auth type the connection stood on when the push was authorized.
typedef LivePush = ({String? enrollmentId, AuthType? authType});

/// One monitor connection's feed of live notifications.
abstract interface class MonitorSink {
  /// The connection this feed writes to.
  InboundConnection get connection;

  /// Completes once every push handed to this feed so far has settled.
  /// Never completes with an error.
  Future<void> get idle;

  /// Queues [n] for this feed's connection, if the feed takes its type. When
  /// [report] is given, the feed settles [n] in it once it has written [n]
  /// or decided not to.
  void push(AtNotification n, {LivePushReport? report});

  /// Ends this feed: pushes still queued are dropped.
  void close();
}

/// The live pushes written for one received notification, sent to
/// [onSettled] once every feed handed the notification has settled it, or
/// once [timeout] passes, whichever is first.
final class LivePushReport {
  /// A report that gives up waiting after [timeout].
  LivePushReport(this._onSettled, {required Duration timeout}) {
    _timer = Timer(timeout, _finish);
  }

  final void Function(List<LivePush> written) _onSettled;
  final List<LivePush?> _slots = <LivePush?>[];
  final Completer<void> _done = Completer<void>();
  late final Timer _timer;
  int _waiting = 0;
  bool _sealed = false;

  /// Completes once the report has been sent.
  Future<void> get done => _done.future;

  /// Counts one more feed that will settle the notification, returning the
  /// slot it settles.
  int expect() {
    _waiting++;
    _slots.add(null);
    return _slots.length - 1;
  }

  /// Records how the feed holding [slot] settled the notification: [push]
  /// when written, null when not.
  void settle(int slot, LivePush? push) {
    _slots[slot] = push;
    _waiting--;
    if (_sealed && _waiting == 0) {
      _finish();
    }
  }

  /// Marks every feed counted, and sends the report at once if none is still
  /// to settle.
  void seal() {
    _sealed = true;
    if (_waiting == 0) {
      _finish();
    }
  }

  void _finish() {
    if (_done.isCompleted) {
      return;
    }
    _timer.cancel();
    _done.complete();
    _onSettled(_slots.nonNulls.toList());
  }
}
