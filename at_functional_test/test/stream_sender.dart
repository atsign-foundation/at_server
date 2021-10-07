import 'dart:io';

import 'package:at_client/at_client.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'at_demo_data.dart' as demo_credentials;
import 'set_encryption_keys.dart';

void main() async {
  try {
    final first_atsign =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
    final second_atsign =
        ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];
    var preference = getsecondAtsignPreference(second_atsign);
    var atClientManager = await AtClientManager.getInstance()
        .setCurrentAtSign(first_atsign, 'wavi', preference);
    var atClient = atClientManager.atClient;
    var streamResult = await atClient.stream(
        '$first_atsign', 'samples/download.jpeg',
        namespace: 'atmosphere');
    // To setup encryption keys
    // await setEncryptionKeys(second_atsign, preference);
    print(streamResult);
  } on Exception catch (e, trace) {
    print(e.toString());
    print(trace);
  }
  exit(1);
}

Future<void> tearDownFunc() async {
  var isExists = await Directory('test/hive').exists();
  if (isExists) {
    Directory('test/hive').deleteSync(recursive: true);
  }
}

AtClientPreference getsecondAtsignPreference(String atsign) {
  var preference = AtClientPreference();
  preference.hiveStoragePath = 'test/hive/client';
  preference.commitLogPath = 'test/hive/client/commit';
  preference.isLocalStoreRequired = true;
  preference.privateKey = demo_credentials.pkamPrivateKeyMap[atsign];
  preference.rootDomain =
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'];
  return preference;
}
