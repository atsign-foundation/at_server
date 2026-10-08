import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// [toLog] with every control character (C0, DEL, C1) written as a visible
/// escape (`\r`, `\x1b`) and every backslash as `\\`, so that each log
/// record stays on one line of printable text and an escape in it always
/// means the character it names. The escaped text is cut once it reaches
/// [cutOffAfter] characters; an escape begun before the cut is finished, so
/// up to 3 more may be kept.
String sanitiseForLogging(String toLog, {int cutOffAfter = 2100}) {
  if (toLog.length <= cutOffAfter && !toLog.codeUnits.any(_isEscaped)) {
    return toLog;
  }
  final StringBuffer sanitised = StringBuffer();
  int taken = 0;
  while (taken < toLog.length && sanitised.length < cutOffAfter) {
    final int codeUnit = toLog.codeUnitAt(taken++);
    sanitised.write(_isEscaped(codeUnit)
        ? _escape(codeUnit)
        : String.fromCharCode(codeUnit));
  }
  if (taken < toLog.length) {
    sanitised.write(' [truncated, ${toLog.length - taken} more chars]');
  }
  return sanitised.toString();
}

bool _isEscaped(int codeUnit) =>
    codeUnit < 0x20 ||
    (codeUnit >= 0x7f && codeUnit <= 0x9f) ||
    codeUnit == 0x5c;

String _escape(int codeUnit) => switch (codeUnit) {
      0x09 => r'\t',
      0x0a => r'\n',
      0x0d => r'\r',
      0x5c => r'\\',
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
