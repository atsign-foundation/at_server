import 'package:at_secondary/src/verb/handler/sync_stream_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  String? fromAtSign;
  bool self = false;
  bool from = false;
  bool isMonitor = false;
  bool isSyncStream = false;
  CommitLogStreamer? commitLogStreamer;
}
