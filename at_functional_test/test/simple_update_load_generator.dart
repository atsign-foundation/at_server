import 'dart:io';

import 'package:at_functional_test/conf/config_util.dart';

import 'commons.dart';

import 'dart:math';
import 'dart:convert';

import 'dart:isolate';

class ParamsForLoadToSend {
  int numUpdates;
  int minSize;
  String keyPrefix;

  ParamsForLoadToSend(this.numUpdates, this.minSize, this.keyPrefix);
}

var random = Random.secure();
String getRandString(int len) {
  var values = List<int>.generate(len, (i) => random.nextInt(255));
  return base64UrlEncode(values);
}

Future<void> sendSomeUpdates(ParamsForLoadToSend params) async {
  var keyPrefix = params.keyPrefix;
  print ("Creating socket for $keyPrefix");
  Socket socket = await getSocket();
  print ("Created socket for $params.keyPrefix");

  for (int i = 1; i <= params.numUpdates; i++) {
    String keyName = params.keyPrefix + "_" + i.toString();
    var keyValueLength = random.nextInt(10 * params.minSize) + params.minSize;
    String keyValue = getRandString(keyValueLength);

    print('Sending update $keyName : keyValue length is $keyValueLength');
    await socketWriter(socket, 'update:public:$keyName$atSignBob $keyValue');

    var updateResponse = await read();
    print('update $keyName response : $updateResponse');

    assert((!updateResponse.contains('Invalid syntax')) && (!updateResponse.contains('null')));
  }
}

var atSignBob = '@bob🛠';
var atSignBobPort = 25003;

Future<Socket> getSocket() async {
  var rootServer = ConfigUtil.getYaml()['root_server']['url'];
  Socket socketBob = await secureSocketConnection(rootServer, atSignBobPort);
  socketListener(socketBob);
  await prepare(socketBob, atSignBob);
  return socketBob;
}

Future<void> main() async {
  Isolate.spawn(sendSomeUpdates, ParamsForLoadToSend(200, 10, "tiny_values"));
  Isolate.spawn(sendSomeUpdates, ParamsForLoadToSend(100, 100, "small_values"));
  Isolate.spawn(sendSomeUpdates, ParamsForLoadToSend(50, 1000, "medium_values"));
  Isolate.spawn(sendSomeUpdates, ParamsForLoadToSend(10, 10000, "large_values"));

  sleep(Duration(seconds:60));

  print ("Buh-bye");
}
