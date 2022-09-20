import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/notification/notification_manager_impl.dart';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/change_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_utils/at_utils.dart';

// UpdateVerbHandler is used to process update verb
// update can be used to update the public/private keys
// Ex: update:public:email@alice alice@atsign.com \n
class UpdateVerbHandler extends ChangeVerbHandler {
  static bool? _autoNotify = AtSecondaryConfig.autoNotify;
  static Update update = Update();

  UpdateVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  //setter to set autoNotify value from dynamic server config "config:set".
  //only works when testingMode is set to true
  static setAutoNotify(bool newState) {
    if (AtSecondaryConfig.testingMode) {
      _autoNotify = newState;
    }
  }

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.update)}:') &&
      !command.startsWith('update:meta');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return update;
  }

  @override
  HashMap<String, String?> parse(String command) {
    var verbParams = super.parse(command);
    if (command.contains('public:')) {
      verbParams.putIfAbsent('isPublic', () => 'true');
    }
    return verbParams;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    // Sets Response bean to the response bean in ChangeVerbHandler
    await super.processVerb(response, verbParams, atConnection);
    var updateParams = _getUpdateParams(verbParams);
    if (updateParams.sharedBy != null &&
        updateParams.sharedBy!.isNotEmpty &&
        AtUtils.formatAtSign(updateParams.sharedBy) !=
            AtSecondaryServerImpl.getInstance().currentAtSign) {
      logger.warning(
          'Invalid update command sharedBy atsign ${AtUtils.formatAtSign(updateParams.sharedBy)} should be same as current atsign ${AtSecondaryServerImpl.getInstance().currentAtSign}');
      throw InvalidAtKeyException(
          'Invalid update command sharedBy atsign ${AtUtils.formatAtSign(updateParams.sharedBy)} should be same as current atsign ${AtSecondaryServerImpl.getInstance().currentAtSign}');
    }
    try {
      // Get the key and update the value
      var forAtSign = updateParams.sharedWith;
      var atSign = updateParams.sharedBy;
      var key = updateParams.atKey;
      var value = updateParams.value;
      var atData = AtData();
      atData.data = value;
      atData.metaData = AtMetaData();
      var ttlMillis = updateParams.metadata!.ttl;
      var ttbMillis = updateParams.metadata!.ttb;
      var ttrMillis = updateParams.metadata!.ttr;
      var isBinary = updateParams.metadata!.isBinary;
      var isEncrypted = updateParams.metadata!.isEncrypted;
      var dataSignature = updateParams.metadata!.dataSignature;
      var ccd = updateParams.metadata!.ccd;
      String? sharedKeyEncrypted = updateParams.metadata!.sharedKeyEnc;
      String? publicKeyChecksum = updateParams.metadata!.pubKeyCS;
      String? encoding = updateParams.metadata!.encoding;

      // Get the key using verbParams (forAtSign, key, atSign)
      if (forAtSign != null) {
        forAtSign = AtUtils.formatAtSign(forAtSign);
        key = '$forAtSign:$key';
      }
      if (atSign != null) {
        atSign = AtUtils.formatAtSign(atSign);
        key = '$key$atSign';
      }
      // Append public: as prefix if key is public
      if (updateParams.metadata!.isPublic != null &&
          updateParams.metadata!.isPublic!) {
        key = 'public:$key';
      }
      var metadata = await keyStore!.getMeta(key);
      var cacheRefreshMetaMap = validateCacheMetadata(metadata, ttrMillis, ccd);
      ttrMillis = cacheRefreshMetaMap[AT_TTR];
      ccd = cacheRefreshMetaMap[CCD];

      //If ttr is set and atsign is not equal to currentAtSign, the key is
      //cached key.
      if (ttrMillis != null &&
          ttrMillis > 0 &&
          atSign != null &&
          atSign != AtSecondaryServerImpl.getInstance().currentAtSign) {
        key = 'cached:$key';
      }

      var atMetadata = AtMetaData()
        ..ttl = ttlMillis
        ..ttb = ttbMillis
        ..ttr = ttrMillis
        ..isCascade = ccd
        ..isBinary = isBinary
        ..isEncrypted = isEncrypted
        ..dataSignature = dataSignature
        ..sharedKeyEnc = sharedKeyEncrypted
        ..pubKeyCS = publicKeyChecksum
        ..encoding = encoding;

      if (_autoNotify!) {
        _notify(
            atSign,
            forAtSign,
            verbParams[AT_KEY],
            value,
            SecondaryUtil.getNotificationPriority(verbParams[PRIORITY]),
            atMetadata);
      }

      // update the key in data store
      var result = await keyStore!.put(key, atData,
          time_to_live: ttlMillis,
          time_to_born: ttbMillis,
          time_to_refresh: ttrMillis,
          isCascade: ccd,
          isBinary: isBinary,
          isEncrypted: isEncrypted,
          dataSignature: dataSignature,
          sharedKeyEncrypted: sharedKeyEncrypted,
          publicKeyChecksum: publicKeyChecksum,
          encoding: encoding);
      response.data = result?.toString();
      var sharedWithForKafka = forAtSign ?? 'None';
      await KafkaMessageBus.getInstance().publish(
          key!, atData, AtSecondaryServerImpl.getInstance().currentAtSign,
          sharedWith: sharedWithForKafka);
    } on InvalidSyntaxException {
      rethrow;
    } on InvalidAtKeyException {
      rethrow;
    } catch (exception) {
      response.isError = true;
      response.errorMessage = exception.toString();
      return;
    }
  }

  void _notify(String? atSign, String? forAtSign, String? key, String? value,
      NotificationPriority priority, AtMetaData atMetaData) {
    if (forAtSign == null) {
      return;
    }
    key = '$forAtSign:$key$atSign';
    DateTime? expiresAt;
    if (atMetaData.ttl != null) {
      expiresAt = DateTime.now().add(Duration(seconds: atMetaData.ttl!));
    }

    var atNotification = (AtNotificationBuilder()
          ..fromAtSign = atSign
          ..toAtSign = forAtSign
          ..notification = key
          ..type = NotificationType.sent
          ..priority = priority
          ..opType = OperationType.update
          ..expiresAt = expiresAt
          ..atValue = value
          ..atMetaData = atMetaData)
        .build();

    NotificationManager.getInstance().notify(atNotification);
  }

  UpdateParams _getUpdateParams(HashMap<String, String?> verbParams) {
    if (verbParams['json'] != null) {
      var jsonString = verbParams['json']!;
      Map jsonMap = jsonDecode(jsonString);
      return UpdateParams.fromJson(jsonMap);
    }
    var updateParams = UpdateParams();
    updateParams.sharedBy = verbParams[AT_SIGN];
    updateParams.sharedWith = verbParams[FOR_AT_SIGN];
    updateParams.atKey = verbParams[AT_KEY];
    updateParams.value = verbParams[AT_VALUE];
    var metadata = Metadata();
    metadata.ttl = AtMetadataUtil.validateTTL(verbParams[AT_TTL]);
    metadata.ttb = AtMetadataUtil.validateTTB(verbParams[AT_TTB]);
    if (verbParams[AT_TTR] != null) {
      metadata.ttr = AtMetadataUtil.validateTTR(int.parse(verbParams[AT_TTR]!));
    }
    metadata.ccd = AtMetadataUtil.getBoolVerbParams(verbParams[CCD]);
    metadata.dataSignature = verbParams[PUBLIC_DATA_SIGNATURE];
    metadata.isBinary = AtMetadataUtil.getBoolVerbParams(verbParams[IS_BINARY]);
    metadata.isEncrypted =
        AtMetadataUtil.getBoolVerbParams(verbParams[IS_ENCRYPTED]);
    metadata.isPublic = AtMetadataUtil.getBoolVerbParams(verbParams[IS_PUBLIC]);
    metadata.sharedKeyEnc = verbParams[SHARED_KEY_ENCRYPTED];
    metadata.pubKeyCS = verbParams[SHARED_WITH_PUBLIC_KEY_CHECK_SUM];
    metadata.encoding = verbParams[ENCODING];
    updateParams.metadata = metadata;
    return updateParams;
  }
}
