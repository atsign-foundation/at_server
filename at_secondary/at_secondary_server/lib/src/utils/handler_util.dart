import 'dart:collection';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/regex_util.dart' as at_regex;
import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_utils.dart';

HashMap<String, String?> getVerbParam(String regex, String command) {
  var regExp = RegExp(regex, caseSensitive: false);
  var regexMatches = at_regex.getMatches(regExp, command);
  if (regexMatches.isEmpty) {
    throw InvalidSyntaxException('Syntax Exception');
  }
  var verbParams = at_regex.processMatches(regexMatches);
  return verbParams;
}

/// Validates the TTR and CCD metadata.
Map<String, dynamic> validateCacheMetadata(
    AtMetaData? metadata, int? ttr_ms, bool? ccd) {
  // If metadata is null, key is new.
  // When key is new, If TTR is populated and CCD is not populated, CCD defaults to false.
  // If TTR is not populated and CCD is populated, Throw InvalidSyntaxException.
  if (metadata == null) {
    ccd = AtMetadataUtil.validateCascadeDelete(ttr_ms, ccd);
  }
  // If metadata is not null, key is existing.
  if (metadata != null) {
    // On existing key, when TTR and CCD are set, update TTR and CCD values.
    if (ttr_ms != null && ccd != null) {
      ccd = AtMetadataUtil.validateCascadeDelete(ttr_ms, ccd);
    }
    // On existing key, if TTR is null and CCD is populated, get existing TTR value.
    if (ttr_ms == null && ccd != null) {
      if (metadata.ttr != null) {
        ttr_ms = metadata.ttr;
        ccd = AtMetadataUtil.validateCascadeDelete(ttr_ms, ccd);
      }
    }
    // On existing key, if CCD is null and TTR is populated, get existing CCD value.
    if (ccd == null && ttr_ms != null) {
      ccd = metadata.isCascade;
      ccd ??= false;
      ttr_ms = AtMetadataUtil.validateTTR(ttr_ms);
    }
  }
  var valueMap = {AT_TTR: ttr_ms, CCD: ccd};
  return valueMap;
}
