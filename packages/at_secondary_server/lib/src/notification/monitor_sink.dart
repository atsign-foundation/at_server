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

  /// Queues [n] for this feed's connection. Completes with the push once [n]
  /// has been written, or with null when it is not written; never with an
  /// error.
  Future<LivePush?> push(AtNotification n);

  /// Ends this feed: pushes still queued are dropped.
  void close();
}
