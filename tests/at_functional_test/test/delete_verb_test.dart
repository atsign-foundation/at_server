import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late String uniqueId;
  OutboundConnectionFactory firstAtSignConnection = OutboundConnectionFactory();
  String firstAtSign =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignName'];
  String firstAtSignHost =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignUrl'];
  int firstAtSignPort =
      ConfigUtil.getYaml()!['firstAtSignServer']['firstAtSignPort'];

  String secondAtSign =
      ConfigUtil.getYaml()!['secondAtSignServer']['secondAtSignName'];

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success', reason: 'Authentication failed when executing test');
  });

  setUp(() {
    // Generates Unique Id for each test that will be appended to keys to prevent
    // same keys being reused.
    uniqueId = Uuid().v4().hashCode.toString();
  });

  test('Delete verb for public key', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:location-$uniqueId$firstAtSign Bengaluru');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    response = await firstAtSignConnection
        .sendRequestToServer('scan location-$uniqueId');
        expect(response, contains('public:location-$uniqueId$firstAtSign'));

    ///DELETE VERB
    response = await firstAtSignConnection
        .sendRequestToServer('delete:public:location-$uniqueId$firstAtSign');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    response = await firstAtSignConnection
        .sendRequestToServer('scan location-$uniqueId$firstAtSign');
    expect(response, isNot('public:location$firstAtSign'));
  });

  test('delete verb with incorrect spelling - negative scenario', () async {
    ///Delete verb
    String response = await firstAtSignConnection
        .sendRequestToServer('deete:phone$firstAtSign');
    expect(response, contains('Invalid syntax'));
  });

  test('delete verb for an emoji key', () async {
    //UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:🦄🦄-$uniqueId$firstAtSign 2emojis');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //SCAN VERB
    response =
        await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
    expect(response, contains('public:🦄🦄-$uniqueId$firstAtSign'));

    //DELETE VERB
    response = await firstAtSignConnection
        .sendRequestToServer('delete:public:🦄🦄-$uniqueId$firstAtSign');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    //SCAN VERB
    response =
        await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
    expect(response, isNot('public:🦄🦄-$uniqueId$firstAtSign'));
  });

  test('delete verb when ccd is true', () async {
    // UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttr:-1:ccd:true:$secondAtSign:hobby-$uniqueId$firstAtSign photography');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    // SCAN VERB in the first atsign
    response = await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
    expect(response, contains('"$secondAtSign:hobby-$uniqueId$firstAtSign"'));

    // DELETE VERB
    response = await firstAtSignConnection
        .sendRequestToServer('delete:$secondAtSign:hobby-$uniqueId$firstAtSign');
    assert(!response.contains('data:null'));

    //SCAN VERB
    response = await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
    expect(response, isNot('"$secondAtSign:hobby-$uniqueId$firstAtSign"'));
  });

  test('Delete verb - delete non existent key', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:location-$uniqueId$firstAtSign India');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///SCAN VERB
    response =
        await firstAtSignConnection.sendRequestToServer('scan $uniqueId');
    expect(response, contains('location-$uniqueId$firstAtSign'));

    ///DELETE VERB
    response = await firstAtSignConnection
        .sendRequestToServer('delete:location-$uniqueId$firstAtSign');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///DELETE VERB AGAIN
    response = await firstAtSignConnection
        .sendRequestToServer('delete:location-$uniqueId$firstAtSign');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));
  });

  test('delete verb for an protected key - signing_publickey', () async {
    // attempt to delete the key
    String response = await firstAtSignConnection
        .sendRequestToServer('delete:public:signing_publickey$firstAtSign');
    // error is an expected behaviour
    assert((response.contains(
            'UnAuthorized client in request : Cannot delete protected key')) &&
        (response.contains('error')));

    // verify that the key is not deleted
    response = await firstAtSignConnection.sendRequestToServer('scan');
    assert(response.contains('public:signing_publickey$firstAtSign'));
  });

  test('delete verb for an protected key - signing_privatekey', () async {
    // attempt to delete the key
    String response = await firstAtSignConnection.sendRequestToServer(
        'delete:$firstAtSign:signing_privatekey$firstAtSign');
    // the error is an expected behaviour
    assert((response.contains(
            'UnAuthorized client in request : Cannot delete protected key')) &&
        (response.contains('error')));

    ///SCAN VERB
    response = await firstAtSignConnection.sendRequestToServer('scan');
    // ensure that the signing_publickey is not deleted
    assert(response.contains('$firstAtSign:signing_privatekey$firstAtSign'));
  });

  test('delete verb for an protected key - encryption_publickey', () async {
    // attempt to delete the key
    String response = await firstAtSignConnection
        .sendRequestToServer('delete:public:publickey$firstAtSign');
    // error is an expected behaviour
    assert((response.contains(
            'UnAuthorized client in request : Cannot delete protected key')) &&
        (response.contains('error')));

    // verify that the key is not deleted
    response = await firstAtSignConnection.sendRequestToServer('scan');
    assert(response.contains('public:publickey$firstAtSign'));
  });

  test('delete verb for an protected key - pkam_publickey', () async {
    // attempt to delete the key
    String response = await firstAtSignConnection
        .sendRequestToServer('delete:privatekey:at_pkam_publickey');
    // the error is an expected behaviour
    assert((response.contains('Invalid syntax')));
  });

  tearDownAll(() {
    firstAtSignConnection.close();
  });
}
