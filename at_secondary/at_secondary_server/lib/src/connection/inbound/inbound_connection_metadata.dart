import 'package:at_commons/at_commons.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  String fromAtSign;
  bool self = false;
  bool from = false;
}
