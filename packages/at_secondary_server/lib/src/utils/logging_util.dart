import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

extension AtConnectionMetadataLogging on AtSignLogger {
  String getAtConnectionLogMessage(
      AtConnectionMetaData atConnectionMetaData, String logMsg) {
    StringBuffer stringBuffer = StringBuffer();
    if (atConnectionMetaData is InboundConnectionMetadata) {
      stringBuffer =
          _getInboundConnectionLogMessage(atConnectionMetaData, stringBuffer);
    }
    if (atConnectionMetaData.sessionID != null) {
      stringBuffer.write('${atConnectionMetaData.sessionID?.hashCode}|');
    }
    stringBuffer.write('$logMsg|');
    return stringBuffer.toString();
  }

  StringBuffer _getInboundConnectionLogMessage(
      InboundConnectionMetadata inboundConnectionMetadata,
      StringBuffer stringBuffer) {
    if (inboundConnectionMetadata.clientId != null) {
      stringBuffer.write('${inboundConnectionMetadata.clientId}|');
    }
    if (inboundConnectionMetadata.appName != null) {
      stringBuffer.write('${inboundConnectionMetadata.appName}|');
    }
    if (inboundConnectionMetadata.appVersion != null) {
      stringBuffer.write('${inboundConnectionMetadata.appVersion}|');
    }
    if (inboundConnectionMetadata.platform != null) {
      stringBuffer.write('${inboundConnectionMetadata.platform}|');
    }
    return stringBuffer;
  }
}
