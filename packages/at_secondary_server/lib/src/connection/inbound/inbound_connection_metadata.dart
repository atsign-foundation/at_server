import 'package:at_commons/atsign.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// Metadata information for [InboundConnection]
class InboundConnectionMetadata extends AtConnectionMetaData {
  /// fromSelf will be true iff 'from' has been executed with the atSign of this atServer
  bool self = false;

  /// fromOther will be true iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  bool from = false;

  /// fromOtherAtSign will be populated iff 'from' has been executed with an atSign which is NOT the atSign of this atServer
  Atsign? fromAtSign;

  /// The target tenant a cross-server peer is operating on, set by the `to:@x`
  /// verb. Single-tenant: always equals this server's atSign when set.
  Atsign? toAtSign;

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

  @override
  String toString() {
    return 'InboundConnectionMetadata{self: $self, from: $from, fromAtSign: $fromAtSign, toAtSign: $toAtSign, clientId: $clientId, appName: $appName, appVersion: $appVersion, platform: $platform, enrollmentId: $enrollmentId}';
  }
}
