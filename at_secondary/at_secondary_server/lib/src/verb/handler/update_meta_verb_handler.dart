import 'dart:collection';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_utils.dart';

class UpdateMetaVerbHandler extends AbstractVerbHandler {
  static final AUTO_NOTIFY = AtSecondaryConfig.autoNotify;
  static UpdateMeta updateMeta = UpdateMeta();

  UpdateMetaVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

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
    var ttl_ms;
    var ttb_ms;
    var ttr_ms;
    var ccd;
    var isBinary;
    var isEncrypted;
    var metadata;
    String? sharedKeyEncrypted, sharedWithPublicKeyChecksum;

    key = _constructKey(key, forAtSign, atSign);
    if (verbParams.containsKey('isPublic')) {
      key = 'public:$key';
    }
    try {
      ttl_ms = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
      ttb_ms = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
      if (ttr_ms != null) {
        ttr_ms = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
      }
      isBinary = AtMetadataUtil.getBoolVerbParams(verbParams[IS_BINARY]);
      isEncrypted = AtMetadataUtil.getBoolVerbParams(verbParams[IS_ENCRYPTED]);
      sharedKeyEncrypted = verbParams[SHARED_KEY_ENCRYPTED];
      sharedWithPublicKeyChecksum =
          verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
      ccd = AtMetadataUtil.getBoolVerbParams(verbParams[CCD]);
      metadata = await keyStore!.getMeta(key);
      var cacheRefreshMetaMap = validateCacheMetadata(metadata, ttr_ms, ccd);
      ttr_ms = cacheRefreshMetaMap[AT_TTR];
      ccd = cacheRefreshMetaMap[CCD];
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
            isEncrypted: isEncrypted,
            sharedKeyEncrypted: sharedKeyEncrypted,
            publicKeyChecksum: sharedWithPublicKeyChecksum)
        .build();

    if (verbParams[AT_CLIENT_LAST_KNOWN_COMMIT_ID_FOR_KEY] != null) {
      int clientCommitId = int.parse(verbParams[AT_CLIENT_LAST_KNOWN_COMMIT_ID_FOR_KEY]!);
      int serverCommitId = await keyStore!.latestCommitIdForKey(key);
      if (clientCommitId < serverCommitId) {
        // Client last known commit id is out of date; reject the update
        throw AtInvalidStateException('update:meta: Client last known commit id $clientCommitId is less than server commit id $serverCommitId - rejecting');
      }
    }

    int commitId = await keyStore!.putMeta(key, atMetaData);
    InboundConnectionMetadata inboundConnectionMetadata = atConnection.getMetaData() as InboundConnectionMetadata;
    if (inboundConnectionMetadata.commitLogStreamer != null) {
      AtChangeEventListener syncStreamListener = inboundConnectionMetadata.commitLogStreamer as AtChangeEventListener;
      syncStreamListener.ignoreCommitId(commitId);
    }

    response.data = commitId.toString();
    // If forAtSign is null, do not auto notify
    if (forAtSign == null || forAtSign.isEmpty) {
      return;
    }
    if (AUTO_NOTIFY! && (atSign != forAtSign)) {
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
