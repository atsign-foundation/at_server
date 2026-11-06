import 'dart:async';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

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

  /// How many notifications wait in this feed to be settled.
  int get queued;

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
///
/// The report is sent, and its timer runs, in the zone it was created in,
/// never inside the call that settled or sealed it; a failure in
/// [onSettled] is logged and goes no further.
final class LivePushReport {
  /// A report on [about] that gives up waiting after [timeout].
  LivePushReport(this._onSettled,
      {required Duration timeout, this.about = 'a notification'})
      : _zone = Zone.current {
    _timer = Timer(timeout, _finish);
  }

  static final AtSignLogger _logger = AtSignLogger('LivePushReport');

  /// What the report is on, for its log lines.
  final String about;

  final Zone _zone;
  final void Function(List<LivePush> written) _onSettled;
  final List<LivePush?> _slots = <LivePush?>[];
  final List<bool> _settled = <bool>[];
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
    _settled.add(false);
    return _slots.length - 1;
  }

  /// How many feeds have been counted.
  int get counted => _slots.length;

  /// Records how the feed holding [slot] settled the notification: [push]
  /// when written, null when not.
  void settle(int slot, LivePush? push) {
    _slots[slot] = push;
    _settled[slot] = true;
    _waiting--;
    if (_sealed && _waiting == 0) {
      _finishSoon();
    }
  }

  /// Settles as not written every slot from [first] on that its feed has
  /// not settled, for a feed that failed after it was counted.
  void abandon(int first) {
    for (int slot = first; slot < _slots.length; slot++) {
      if (!_settled[slot]) {
        settle(slot, null);
      }
    }
  }

  /// Marks every feed counted, and sends the report as soon as none is
  /// still to settle.
  void seal() {
    _sealed = true;
    if (_waiting == 0) {
      _finishSoon();
    }
  }

  void _finishSoon() => _zone.scheduleMicrotask(_finish);

  void _finish() {
    if (_done.isCompleted) {
      return;
    }
    _timer.cancel();
    _done.complete();
    try {
      _onSettled(_slots.nonNulls.toList());
    } catch (e, st) {
      _logger.severe('$e while sending the report on $about\n$st');
    }
  }
}
