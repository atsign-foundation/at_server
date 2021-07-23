import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:at_client/src/client/at_client_impl.dart';
import 'package:at_functional_test/conf/config_util.dart';
import 'set_encryption_keys.dart';
import 'at_demo_data.dart' as demo_credentials;

AtClientImpl atClient;

void main() async {
  try {
    var atsign =
        ConfigUtil.getYaml()['first_atsign_server']['first_atsign_name'];
    var preference = getfirstAtsignPreference(atsign);
    await AtClientImpl.createClient(atsign, 'me', preference);
    atClient = await AtClientImpl.getClient(atsign);
    atClient.getSyncManager().init(atsign, preference,
        atClient.getRemoteSecondary(), atClient.getLocalSecondary());
    await setEncryptionKeys(atsign, preference);
    await atClient.startMonitor(preference.privateKey, _notificationCallBack,
        regex: 'atmosphere');
  } on Exception catch (e, trace) {
    print(e.toString());
    print(trace);
  }
}

Future<void> _notificationCallBack(var response) async {
  response = response.replaceFirst('notification:', '');
  var responseJson = jsonDecode(response);
  var notificationKey = responseJson['key'];
  var fromAtSign = responseJson['from'];
  var atKey = notificationKey.split(':')[1];
  atKey = atKey.replaceFirst(fromAtSign, '');
  atKey = atKey.trim();
  if (atKey == 'stream_id.atmosphere') {
    var valueObject = responseJson['value'];
    var streamId = valueObject.split(':')[0];
    var fileName = valueObject.split(':')[1];
    var fileLength = int.parse(valueObject.split(':')[2]);
    fileName = utf8.decode(base64.decode(fileName));
    var userResponse = true; //UI user response
    if (userResponse == true) {
      print('user accepted transfer.Sending ack back');
      await atClient.sendStreamAck(streamId, fileName, fileLength, fromAtSign,
          _streamCompletionCallBack, _streamReceiveCallBack);
    }
  } else {
    //TODO handle other notifications
    print('some other notification');
    print(response);
  }
}

void _streamReceiveCallBack(var bytesReceived) {
  print('Receive callback bytes received: $bytesReceived');
}

void _streamCompletionCallBack(var streamId) {
  print('Transfer done for stream: $streamId');
}

AtClientPreference getfirstAtsignPreference(String atsign) {
  var preference = AtClientPreference();
  preference.hiveStoragePath = 'hive/client';
  preference.commitLogPath = 'hive/client/commit';
  preference.isLocalStoreRequired = true;
  preference.syncStrategy = SyncStrategy.IMMEDIATE;
  preference.downloadPath = 'samples/download/download.jpeg';
  preference.privateKey = demo_credentials.pkamPrivateKeyMap[atsign];
  preference.rootDomain =
      ConfigUtil.getYaml()['first_atsign_server']['first_atsign_url'];
  return preference;
}
