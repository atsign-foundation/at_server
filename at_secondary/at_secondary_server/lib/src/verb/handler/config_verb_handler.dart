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

enum ConfigOp { ADD, REMOVE, SHOW }

extension Value on ConfigOp {
  String get name {
    return toString().split('.').last.toLowerCase();
  }
}

/// [ConfigVerbHandler] processes 'config' verb.
///
/// 'config' can be used to configure/view block/allow list of an [@sign].
/// ```
/// Example
///   1. config:block:add:@alice @bob //adds @alice @bob into blocklist
///   2. config:block:show //shows blocklist
/// ```
class ConfigVerbHandler extends AbstractVerbHandler {
  static Config config = Config();
  ConfigVerbHandler(SecondaryKeyStore? keyStore) : super(keyStore);

  late var atConfigInstance;
  late ModifiableConfigs? setConfigName;
  late String? setConfigValue;

  @override
  bool accept(String command) =>
      command.startsWith(getName(VerbEnum.config) + ':');

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
      var currentAtSign = AtSecondaryServerImpl.getInstance().currentAtSign;
      atConfigInstance = AtConfig(
          await AtCommitLogManagerImpl.getInstance()
              .getCommitLog(currentAtSign),
          currentAtSign);
      var result;
      var operation = verbParams[AT_OPERATION];
      var atsigns = verbParams[AT_SIGN];
      String? setOperation = verbParams[SET_OPERATION];

      switch (operation) {
        case 'show':
          var blockList = await atConfigInstance.getBlockList();
          result = (blockList != null && blockList.isNotEmpty)
              ? _toJsonResponse(blockList)
              : null;
          break;
        case 'add':
          var nonCurrentAtSignList =
              _retainNonCurrentAtsign(currentAtSign, atsigns!);
          if (nonCurrentAtSignList.isNotEmpty) {
            result =
                await atConfigInstance.addToBlockList(nonCurrentAtSignList);
          }

          ///if list contains only currentAtSign
          else {
            result = 'success';
          }
          break;
        case 'remove':
          result = await atConfigInstance.removeFromBlockList(_toSet(atsigns!));
          break;
        default:
          result = 'unknown operation';
          break;
      }

      //in case of config:set the config input received is in the form of 'config=value'. The below if condition splits that and separated config name to config value
      if (setOperation == 'set') {
        //split 'config=value' to array of strings
        var newConfig = verbParams[CONFIG_NEW]?.split('=');
        //first element of array is config name
        setConfigName = ModifiableConfigs.values.byName(newConfig![0]);
        //second element of array is config value
        setConfigValue = newConfig[1];
      } else {
        //in other cases reset/print only config name is received
        setConfigName =
            ModifiableConfigs.values.byName(verbParams[CONFIG_NEW]!);
      }

      //implementation for config:set
      switch (setOperation) {
        case 'set':
          if (AtSecondaryConfig.testingMode) {
            //broadcast new config change
            try {
              AtSecondaryConfig.broadcastConfigChange(
                  setConfigName!, int.parse(setConfigValue!));
            } catch (e) {
              AtSecondaryConfig.broadcastConfigChange(
                  setConfigName!, setConfigValue!);
            }
            ;
            result = 'ok';
          } else {
            result = 'testing mode disabled by default';
          }
          break;
        case 'reset':
          if (AtSecondaryConfig.testingMode) {
            //broadcast reset
            AtSecondaryConfig.broadcastConfigChange(setConfigName!, null,
                isReset: true);
            result = 'ok';
          } else {
            result = 'testing mode disabled by default';
          }
          break;
        case 'print':
          if (AtSecondaryConfig.testingMode) {
            result = AtSecondaryConfig.getLatestConfigValue(setConfigName!);
          } else {
            result = 'testing mode disabled by default';
          }
          break;
        default:
          result = 'invalid setOperation';
          break;
      }
      response.data = result?.toString();
    } catch (exception) {
      response.isError = true;
      response.errorMessage = exception.toString();
      rethrow;
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
