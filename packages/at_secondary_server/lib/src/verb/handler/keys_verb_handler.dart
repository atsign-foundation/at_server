import 'dart:collection';
import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_server_spec/at_verb_spec.dart';

class KeysVerbHandler extends AbstractVerbHandler {
  static Keys keys = Keys();

  KeysVerbHandler(SecondaryKeyStore keyStore) : super(keyStore);

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) => command.startsWith('keys:');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return keys;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    final keyVisibility = verbParams[visibility];
    final keyNamespace = verbParams[namespace];
    final atSign = AtSecondaryServerImpl.getInstance().currentAtSign;
    final value = verbParams[keyValue];
    final valueJson = {};
    valueJson['value'] = value;
    valueJson['keyType'] = verbParams[keyType];
    final operation = verbParams[AT_OPERATION];
    switch (operation) {
      case 'put':
        try {
          logger.finer('value:$valueJson');
          // update the key in data store
          final atData = AtData();
          atData.data = value;
          var result;
          // for backward compatibility, store the default encryption public key as ref key to public:publickey
          if (keyVisibility == 'public' && keyNamespace == '__global') {
            final publicKeyName = _getPublicKeyName(verbParams, atSign);
            result = await keyStore.put(publicKeyName, atData);
            logger.finer('publicKeyName:$publicKeyName');
            final refKeyName = publicKeyName.replaceFirst('public:', '');
            logger.finer('refKeyName: $refKeyName');
            await keyStore.put('public:publickey$atSign',
                AtData()..data = 'atsign://$refKeyName');
          }
          response.data = result.toString();
        } catch (e, st) {
          logger.warning('$e\n$st');
        }
        break;
    }
  }

  String _getPublicKeyName(HashMap<String, String?> verbParams, String atSign) {
    return '${verbParams[visibility]}${verbParams[keyName]}.__${verbParams[visibility]}_keys.${verbParams[namespace]}$atSign';
  }
}
