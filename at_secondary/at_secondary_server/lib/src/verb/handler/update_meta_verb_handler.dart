import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

class UpdateMetaVerbHandler extends AbstractVerbHandler {
  static bool _autoNotify = AtSecondaryConfig.autoNotify;
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
  static setAutoNotify(bool newState) {
    if (AtSecondaryConfig.testingMode) {
      _autoNotify = newState;
    }
  }

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.update) + ':') &&
      command.startsWith('update:meta:');

  @override
  Verb getVerb() => updateMeta;

  @override
  HashMap<String, String?> parse(String command) {
    var verbParams = super.parse(command);
    if (command.contains('public:')) {
      verbParams.putIfAbsent('isPublic', () => 'true');
    }
    return verbParams;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var forAtSign = verbParams[FOR_AT_SIGN];
    forAtSign = AtUtils.formatAtSign(forAtSign);
    var atSign = verbParams[AT_SIGN];
    atSign = AtUtils.formatAtSign(atSign);

    var key = verbParams[AT_KEY];
    int ttlMillis;
    int ttbMillis;
    int? ttrMillis;
    bool ccd;
    bool isBinary;
    bool isEncrypted;
    AtMetaData? metadata;
    String? sharedKeyEncrypted, sharedWithPublicKeyChecksum;

    key = _constructKey(key, forAtSign, atSign);
    if (verbParams.containsKey('isPublic')) {
      key = 'public:$key';
    }
    try {
      ttlMillis = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttbMillis = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (ttrMillis != null) {
        ttrMillis = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
      }
      isBinary = AtMetadataUtil.getBoolVerbParams(verbParams[IS_BINARY]);
      isEncrypted = AtMetadataUtil.getBoolVerbParams(verbParams[IS_ENCRYPTED]);
      sharedKeyEncrypted = verbParams[SHARED_KEY_ENCRYPTED];
      sharedWithPublicKeyChecksum =
          verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
      ccd = AtMetadataUtil.getBoolVerbParams(verbParams[CCD]);
      metadata = await keyStore!.getMeta(key);
      var cacheRefreshMetaMap = validateCacheMetadata(metadata, ttrMillis, ccd);
      ttrMillis = cacheRefreshMetaMap[AT_TTR];
      ccd = cacheRefreshMetaMap[CCD];
    } on InvalidSyntaxException {
      rethrow;
    }
    var atMetaData = AtMetadataBuilder(
            newAtMetaData: metadata,
            ttl: ttlMillis,
            ttb: ttbMillis,
            ttr: ttrMillis,
            ccd: ccd,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: sharedWithPublicKeyChecksum)
        .build();
    var result = await keyStore!.putMeta(key, atMetaData);
    response.data = result?.toString();
    // If forAtSign is null, do not auto notify
    if (forAtSign == null || forAtSign.isEmpty) {
      return;
    }
    if (_autoNotify && (atSign != forAtSign)) {
      _notify(
          forAtSign,
          atSign,
          key,
          SecondaryUtil().getNotificationPriority(verbParams[PRIORITY]),
          atMetaData);
    }
  }

  String _constructKey(String? key, String? forAtSign, String? atSign) {
    if (forAtSign != null && forAtSign.isNotEmpty) {
      key = '$forAtSign:$key';
    }
    key = '$key$atSign';
    return key;
  }

  void _notify(forAtSign, atSign, key, priority, AtMetaData? atMetaData) {
    if (forAtSign == null) {
      return;
    }
    var atNotification = (AtNotificationBuilder()
          ..type = NotificationType.sent
          ..fromAtSign = atSign
          ..toAtSign = forAtSign
          ..notification = key
          ..priority = priority
          ..atMetaData = atMetaData)
        .build();
    NotificationManager.getInstance().notify(atNotification);
  }
}
