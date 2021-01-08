import 'dart:collection';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_spec/src/keystore/secondary_keystore.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/notification_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/src/connection/inbound_connection.dart';
import 'package:at_server_spec/src/verb/response.dart';
import 'package:at_server_spec/src/verb/verb.dart';
import 'package:at_server_spec/src/verb/update_meta.dart';
import 'package:at_commons/src/at_constants.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';
import 'package:at_secondary/src/utils/handler_util.dart';

class UpdateMetaVerbHandler extends AbstractVerbHandler {
  static final AUTO_NOTIFY = AtSecondaryConfig.autoNotify;
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.update) + ':') &&
          command.startsWith('update:meta:');

  @override
  Verb getVerb() => updateMeta;

  @override
  HashMap<String, String> parse(String command) {
    var verbParams = super.parse(command);
    if (command.contains('public:')) {
      verbParams.putIfAbsent('isPublic', () => 'true');
    }
    return verbParams;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String> verbParams,
      InboundConnection atConnection) async {
    var forAtSign = verbParams[FOR_AT_SIGN];
    var atSign = verbParams[AT_SIGN];
    var key = verbParams[AT_KEY];
    var ttl_ms;
    var ttb_ms;
    var ttr_ms;
    var ccd;
    var isBinary;
    var isEncrypted;
    var metadata;

    key = _constructKey(key, forAtSign, atSign);
    if (verbParams.containsKey('isPublic')) {
      key = 'public:${key}';
    }
    try {
      ttl_ms = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttb_ms = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (ttr_ms != null) {
        ttr_ms = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]));
      }
      isBinary = AtMetadataUtil.getBoolVerbParams(verbParams[IS_BINARY]);
      isEncrypted = AtMetadataUtil.getBoolVerbParams(verbParams[IS_ENCRYPTED]);
      ccd = AtMetadataUtil.getBoolVerbParams(verbParams[CCD]);
      metadata = await keyStore.getMeta(key);
      var cacheRefreshMetaMap = validateCacheMetadata(metadata, ttr_ms, ccd);
      if (cacheRefreshMetaMap != null) {
        ttr_ms = cacheRefreshMetaMap[AT_TTR];
        ccd = cacheRefreshMetaMap[CCD];
      }
    } on InvalidSyntaxException {
      rethrow;
    }
    var atMetaData = AtMetadataBuilder(
        newAtMetaData: metadata,
        ttl: ttl_ms,
        ttb: ttb_ms,
        ttr: ttr_ms,
        ccd: ccd,
        isBinary: isBinary,
        isEncrypted: isEncrypted)
        .build();
    var result = await keyStore.putMeta(key, atMetaData);
    response.data = result?.toString();
    // If forAtSign is null, do not auto notify
    if (forAtSign == null) {
      return;
    }
    if (AUTO_NOTIFY && (atSign != forAtSign)) {
      key = _constructKeyToNotify(key, forAtSign, ttl_ms, ttb_ms, ttr_ms, ccd);
      try {
        await NotificationUtil.sendNotification(forAtSign, atConnection, key);
      } catch (exception) {
        logger.severe(
            'Exception while sending notification ${exception.toString()}');
      }
    }
  }

  String _constructKeyToNotify(
      String key,
      String forAtSign,
      int ttl_ms,
      int ttb_ms,
      int ttr_ms,
      bool isCascade,
      ) {
    forAtSign = AtUtils.formatAtSign(forAtSign);
    //if ttr is set, notify with value.
    if (isCascade != null) {
      key = '$CCD:$isCascade:$key';
    }
    if (ttr_ms != null) {
      key = '$AT_TTR:$ttr_ms:$key';
    }
    if (ttb_ms != null) {
      key = '$AT_TTB:$ttb_ms:$key';
    }
    if (ttl_ms != null) {
      key = '$AT_TTL:$ttl_ms:$key';
    }
    key = 'update:$key';
    return key;
  }

  String _constructKey(String key, String forAtSign, String atSign) {
    if (forAtSign != null) {
      forAtSign = AtUtils.formatAtSign(forAtSign);
      key = '${forAtSign}:${key}';
    }
    atSign = AtUtils.formatAtSign(atSign);
    key = '${key}${atSign}';
    return key;
  }
}
