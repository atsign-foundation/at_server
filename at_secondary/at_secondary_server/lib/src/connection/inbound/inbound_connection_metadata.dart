import 'package:at_server_spec/at_server_spec.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  String fromAtSign;
  bool self = false;
  bool from = false;
}
