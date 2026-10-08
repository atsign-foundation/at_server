import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// The C0 and C1 control characters, and DEL.
final RegExp _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');

/// [toLog] cut to [cutOffAfter] characters, with every control character
/// written as a visible escape (`\r`, `\x1b`), so that each log record
/// stays on one line of printable text.
String sanitiseForLogging(String toLog, {int cutOffAfter = 2100}) {
  if (toLog.length > cutOffAfter) {
    toLog =
        '${toLog.substring(0, cutOffAfter)} [truncated, ${toLog.length - cutOffAfter} more chars]';
  }
  return toLog.replaceAllMapped(
      _controlCharacters, (m) => _escape(m[0]!.codeUnitAt(0)));
}

String _escape(int codeUnit) => switch (codeUnit) {
      0x09 => r'\t',
      0x0a => r'\n',
      0x0d => r'\r',
      _ => '\\x${codeUnit.toRadixString(16).padLeft(2, '0')}',
    };

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
    stringBuffer.write(logMsg);
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
