import 'dart:collection';
import 'dart:convert';
import 'package:at_secondary/src/server/at_secondary_config.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_commons/at_commons.dart';

/// [ConfigVerbHandler] processes 'config' verb.
///
/// 'config' can be used for three types of operations:
/// 1. config:block:[..] to configure/view block/allow list of an [@sign]
/// ```
/// Examples:
///   config:block:add:@alice @bob //adds @alice @bob into blocklist
///   config:block:show //shows blocklist
/// ```
/// 2. config:set:name=value to change config parameters while server is running.
/// `config:set` requires the server to be in testing mode
/// 3. config:reset:name to reset config parameters back to defaults while server is running.
/// `config:reset` requires the server to be in testing mode
/// 4. config:print:name to return the current values for the various configurable parameters.
/// `config:print` requires the server to be in testing mode
///
class ConfigVerbHandler extends AbstractVerbHandler {
  static Config config = Config();

  ConfigVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.config)}:');

  @override
  Verb getVerb() {
    return config;
  }

  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    try {
      var operation = verbParams[AT_OPERATION];
      var atsigns = verbParams[AT_SIGN];
      String? setOperation = verbParams[SET_OPERATION];

      if (operation != null) {
        await handleBlockListOperations(operation, response, atsigns);
      } else if (setOperation != null) {
        // 'operation' parameter not provided, in which case the verb syntax requires that 'setOperation' should be provided instead
        handleDynamicConfigOperations(setOperation, verbParams, response);
      }
    } catch (exception) {
      response.isError = true;
      response.errorMessage = exception.toString();
      rethrow;
    }
  }

  void handleDynamicConfigOperations(String setOperation, HashMap<String, String?> verbParams, Response response) {
    //in case of config:set the config input received is in the form of 'config=value'. The below if condition splits that and separates config name and config value
    late ModifiableConfigs configName;
    dynamic configValue;

    if (setOperation == 'set') {
      //split 'config=value' to array of strings
      var newConfig = verbParams[CONFIG_NEW]?.split('=');
      //first element of array is config name
      configName = ModifiableConfigs.values.byName(newConfig![0]);
      //second element of array is config value
      configValue = newConfig[1];
      if (configName.isInt) {
        configValue = int.parse(configValue);
      }
    } else {
      //in other cases reset/print only config name is received
      configName = ModifiableConfigs.values.byName(verbParams[CONFIG_NEW]!);
    }

    if (!AtSecondaryConfig.testingMode && configName.requireTestingMode) {
      response.data = 'testing mode disabled by default';
      return;
    }

    switch (setOperation) {
      case 'set':
        AtSecondaryConfig.broadcastConfigChange(configName, configValue!);
        response.data = 'ok';
        break;
      case 'reset':
        AtSecondaryConfig.broadcastConfigChange(configName, null,
            isReset: true);
        response.data = 'ok';
        break;
      case 'print':
        response.data = AtSecondaryConfig.getLatestConfigValue(configName);
        break;
      default:
        response.data = 'invalid setOperation';
        break;
    }
    return;
  }

  Future<void> handleBlockListOperations(String operation, Response response, String? atsigns) async {
    var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    AtConfig atConfigInstance = AtConfig(
        await AtCommitLogManagerImpl.getInstance()
            .getCommitLog(currentAtSign),
        currentAtSign);

    switch (operation) {
      case 'show':
        var blockList = await atConfigInstance.getBlockList();
        response.data =
            (blockList.isNotEmpty) ? _toJsonResponse(blockList) : null;
        break;
      case 'add':
        var nonCurrentAtSignList =
            _retainNonCurrentAtsign(currentAtSign, atsigns!);
        if (nonCurrentAtSignList.isNotEmpty) {
          response.data =
              await atConfigInstance.addToBlockList(nonCurrentAtSignList);
          break;
        } else {
          // list contains only currentAtSign
          response.data = 'success';
        }
        break;
      case 'remove':
        response.data =
            await atConfigInstance.removeFromBlockList(_toSet(atsigns!));
        break;
      default:
        response.data = 'unknown operation';
        break;
    }
  }
}

/// Returns atsigns set.
Set<String> _toSet(String atsign) {
  var stringList = Set<String>.from(atsign.split(' '));
  return stringList;
}

///returns atsigns set by removing currentAtSign if exists.
Set<String> _retainNonCurrentAtsign(String currentAtSign, String atsign) {
  var nonCurrentAtSignsList = _toSet(atsign);
  nonCurrentAtSignsList.removeWhere((data) => data == currentAtSign);
  return nonCurrentAtSignsList;
}

///converts [data] into json.
String _toJsonResponse(Set<String> data) {
  var jsonResponse = [];
  for (var d in data) {
    jsonResponse.add(d);
  }
  return jsonEncode(jsonResponse);
}
