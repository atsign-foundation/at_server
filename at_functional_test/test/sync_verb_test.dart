import 'dart:io';

import 'package:test/test.dart';

import 'commons.dart';
import 'package:at_functional_test/conf/config_util.dart';

void main() {
  var firstAtsign =
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'];
  Socket? socketFirstAtsign;

  setUp(() async {
    var firstAtsignServer = ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'];
    var firstAtsignPort =
        ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'];

    socketFirstAtsign =
        await secure_socket_connection(firstAtsignServer, firstAtsignPort);
    socket_listener(socketFirstAtsign!);
    await prepare(socketFirstAtsign!, firstAtsign);
  });

  test('sync verb with regex ', () async {
    /// UPDATE VERB
    await socket_writer(socketFirstAtsign!,
        'update:public:twitter.persona$firstAtsign bob_tweet');
    var response = await read();
    print('update verb response : $response');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
    var commitId = response.replaceAll('data:', '');
    var syncId = int.parse(commitId);
    var regex = '.persona';

    // sync with regex
    await socket_writer(socketFirstAtsign!, 'sync:from:${syncId - 1}:limit:5:$regex');
    response = await read();
    print('sync response is : $response');
    assert((response.contains('"atKey":"public:twitter$regex$firstAtsign')) &&
        (!response.contains('"atKey":"public:location$firstAtsign')));
  });

  // sync negative scenario
  test('sync verb with only regex and no commit Id ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(socketFirstAtsign!, 'sync:$regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  test('sync verb in an incorrect format ', () async {
    /// UPDATE VERB
    var regex = '.buzz@';
    await socket_writer(socketFirstAtsign!, 'sync $regex');
    var response = await read();
    print('update verb response : $response');
    assert((response.contains('Invalid syntax')));
  });

  tearDown(() {
    //Closing the client socket connection
    clear();
    socketFirstAtsign!.destroy();
  });
}
