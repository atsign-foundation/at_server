import 'package:at_server_spec/at_server_spec.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  /// fromSelf will be true iff 'from' has been executed with the atSign of this atServer
  bool fromSelf = false;

  /// fromOther will be true iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  bool fromOther = false;

  /// fromOtherAtSign will be populated iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  String? fromOtherAtSign;
}
