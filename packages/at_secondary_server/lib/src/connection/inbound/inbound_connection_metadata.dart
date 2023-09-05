import 'package:at_server_spec/at_server_spec.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  /// fromSelf will be true iff 'from' has been executed with the atSign of this atServer
  bool self = false;

  /// fromOther will be true iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  bool from = false;

  /// fromOtherAtSign will be populated iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  String? fromAtSign;

  /// A unique identifier to distinguish clients in the server logs.
  String? clientId;

  /// The name of the app the InboundConnection is associated with. This helps to
  /// know app that is sending the request.
  String? appName;

  /// The version of the app
  String? appVersion;

  /// The platform on which the client(origin of connection) is running
  String? platform;

  /// A unique identifier generated for a client's APKAM enroll request
  String? enrollmentId;
}
