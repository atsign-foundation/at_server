import 'dart:convert';
import 'dart:math';

import 'package:at_functional_test/conf/config_util.dart';
import 'package:at_functional_test/connection/outbound_connection_wrapper.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() async {
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

  var lastValue = Random().nextInt(20);

  setUpAll(() async {
    await firstAtSignConnection.initiateConnectionWithListener(
        firstAtSign, firstAtSignHost, firstAtSignPort);
    String authResponse = await firstAtSignConnection.authenticateConnection();
    expect(authResponse, 'data:success',
        reason: 'Authentication failed when executing test');
  });

  setUp(() {
    uniqueId = Uuid().v4();
  });

  updateLookupUpdateDeleteForceDeleteImmutable(String atKey) async {
    // Create the data
    var value = 'Immutable data $lastValue';
    var response = await firstAtSignConnection
        .sendRequestToServer('update:immutable:true:$atKey $value');
    expect(response, contains(RegExp(r'data:\d+')));

    // Look it up
    response =
        await firstAtSignConnection.sendRequestToServer('llookup:$atKey');
    expect(response, contains('data:$value'));

    // Try to update it again - should fail
    response = await firstAtSignConnection
        .sendRequestToServer('update:immutable:true:$atKey $value');
    expect(response, contains('error:{"errorCode":"AT0032",'));

    // Try to delete it without the "force" flag - should fail
    response = await firstAtSignConnection.sendRequestToServer('delete:$atKey');
    expect(response, contains('error:{"errorCode":"AT0032",'));

    // Try to delete it WITH the "force" flag - should succeed
    response =
        await firstAtSignConnection.sendRequestToServer('delete:force:$atKey');
    expect(response, contains(RegExp(r'data:\d+')));
  }

  test('update llookup update delete and force delete with immutable public',
      () async {
    String atKey = 'public:immutable-$uniqueId$firstAtSign';
    await updateLookupUpdateDeleteForceDeleteImmutable(atKey);
  });

  test('update llookup update delete and force delete with immutable self',
      () async {
    String atKey = 'immutable-$uniqueId$firstAtSign';
    await updateLookupUpdateDeleteForceDeleteImmutable(atKey);
  });

  test('update llookup update delete and force delete with immutable shared',
      () async {
    String atKey = '$secondAtSign:immutable-$uniqueId$firstAtSign';
    await updateLookupUpdateDeleteForceDeleteImmutable(atKey);
  });

  /// An immutable record carrying a ttl is a create-once interlock that
  /// releases itself: the refusal of the second create IS the lock, and the
  /// ttl is what stops a holder that died mid-operation from blocking its own
  /// atSign for good. Several clients of one atSign use it to elect exactly
  /// one of themselves to perform an operation.
  ///
  /// That only works if expiry frees the NAME and not merely the value.
  /// Before this was fixed the two disagreed — `llookup` answered that the
  /// record was gone while `update` went on refusing to create it — so the
  /// ttl expired the value but the record remained in the data store
  /// until the expired-keys cleanup sweep next ran.
  group('immutable records with a ttl', () {
    test('an EXPIRED immutable record may be created again', () async {
      String atKey = 'expiringlock-$uniqueId$firstAtSign';

      var response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:1000:immutable:true:$atKey first holder');
      expect(response, contains(RegExp(r'data:\d+')));

      // Control. Without this, the acceptance below could mean immutability
      // stopped working altogether rather than that the record expired.
      response = await firstAtSignConnection.sendRequestToServer(
          'update:immutable:true:$atKey second holder');
      expect(response, contains('error:{"errorCode":"AT0032",'),
          reason: 'while it is LIVE the record must still refuse a second '
              'create — that refusal is the interlock itself');

      await Future.delayed(Duration(milliseconds: 1500));

      // The reader already says it is gone. Asserted as "does not carry the
      // value" rather than against a particular error shape, so this pins the
      // property rather than the spelling of a response.
      response =
          await firstAtSignConnection.sendRequestToServer('llookup:$atKey');
      expect(response, isNot(contains('first holder')),
          reason: 'the premise: past its ttl the record is gone to a reader. '
              'If it still reads, the assertion below proves nothing about '
              'expiry');

      // …and the writer must agree.
      response = await firstAtSignConnection.sendRequestToServer(
          'update:ttl:60000:immutable:true:$atKey second holder');
      expect(response, contains(RegExp(r'data:\d+')),
          reason: 'an expired record is gone, so it must not go on refusing a '
              'create. Otherwise a ttl on an immutable record expires the '
              'value while reserving the name for ever, and a lock whose '
              'holder crashed blocks its atSign permanently');

      response =
          await firstAtSignConnection.sendRequestToServer('llookup:$atKey');
      expect(response, contains('data:second holder'));

      await firstAtSignConnection.sendRequestToServer('delete:force:$atKey');
    });

    test('a NOT-YET-BORN immutable record still refuses a second create',
        () async {
      // The other half of the rule, and the reason the check is expiry only
      // rather than the server's general is-this-record-active test: a record
      // inside its ttb has not stopped existing, it has not started yet.
      // Treating it as absent would let a second writer replace a record that
      // is about to become visible.
      String atKey = 'unbornlock-$uniqueId$firstAtSign';

      var response = await firstAtSignConnection.sendRequestToServer(
          'update:ttb:60000:immutable:true:$atKey first holder');
      expect(response, contains(RegExp(r'data:\d+')));

      response =
          await firstAtSignConnection.sendRequestToServer('llookup:$atKey');
      expect(response, isNot(contains('first holder')),
          reason: 'the premise: inside its ttb the record does not read either '
              '— which is exactly why "does not read" cannot be the test for '
              'whether a create is allowed');

      response = await firstAtSignConnection.sendRequestToServer(
          'update:immutable:true:$atKey second holder');
      expect(response, contains('error:{"errorCode":"AT0032",'),
          reason: 'not-yet-born is not gone. The record exists and will become '
              'visible, so a second create must still be refused');

      await firstAtSignConnection.sendRequestToServer('delete:force:$atKey');
    });

    test('an immutable record with NO ttl still refuses a create for ever',
        () async {
      // The behaviour that must not change. Everything above narrows when
      // immutability stops applying; this pins that it still applies at all.
      String atKey = 'permanentlock-$uniqueId$firstAtSign';

      try {
        var response = await firstAtSignConnection
            .sendRequestToServer('update:immutable:true:$atKey first holder');
        expect(response, contains(RegExp(r'data:\d+')));

        await Future.delayed(Duration(milliseconds: 1500));

        response = await firstAtSignConnection
            .sendRequestToServer('update:immutable:true:$atKey second holder');
        expect(response, contains('error:{"errorCode":"AT0032",'),
            reason: 'with no ttl there is nothing to expire, so the record '
                'refuses a create for as long as it exists');
      } finally {
        await firstAtSignConnection.sendRequestToServer('delete:force:$atKey');
      }
    });
  });

  test('update-llookup verb with public key', () async {
    /// UPDATE VERB
    var value = 'Hyderabad$lastValue';
    var response = await firstAtSignConnection.sendRequestToServer(
        'update:public:location-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:location-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb with special characters', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:passcode-$uniqueId$firstAtSign @!ice^&##');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:passcode-$uniqueId$firstAtSign');
    expect(response, contains('data:@!ice^&##'));
  });

  test('update verb with unicode characters', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:unicode-$uniqueId$firstAtSign U+0026');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:unicode-$uniqueId$firstAtSign');
    expect(response, contains('data:U+0026'));
  });

  test('update verb with spaces ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hey Hello! welcome to the tests');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hey Hello! welcome to the tests'));
  });

  test('updating same key with different values and doing a llookup ',
      () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hey Hello! welcome to the tests');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hey Hello! welcome to the tests'));

    response = await firstAtSignConnection.sendRequestToServer(
        'update:public:message-$uniqueId$firstAtSign Hope you are doing good');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:message-$uniqueId$firstAtSign');
    expect(response, contains('data:Hope you are doing good'));
  });

  test('update verb without value should throw a error ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:key-1-$uniqueId$firstAtSign');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb by passing emoji as value ', () async {
    ///UPDATE VERB
    var value = '🦄$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:emoji-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:emoji-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing japanese input as value ', () async {
    ///UPDATE VERB
    var value = 'パーニマぱーにま$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:japanese-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:public:japanese-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update verb by passing 2 @ symbols ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:country@$firstAtSign USA');
    expect(response, contains('Invalid syntax'));
  });

  test('update verb with public and shared with atsign should throw a error ',
      () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:public:@alice:invalid-key$firstAtSign invalid-value');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0003');
    assert(errorMap['errorDescription'].contains('Invalid syntax'));
  });

  test('update verb key with punctuation - check invalid key ', () async {
    ///UPDATE VERB
    String response = await firstAtSignConnection
        .sendRequestToServer('update:public:country,current$firstAtSign USA');
    response = response.replaceFirst('error:', '');
    var errorMap = jsonDecode(response);
    expect(errorMap['errorCode'], 'AT0016');
    assert(errorMap['errorDescription'].contains(
        'Invalid key : You may not update keys of type KeyType.invalidKey'));
  });

  test('update-llookup for private key for an emoji atsign ', () async {
    ///UPDATE VERB
    var value = 'unicorn$lastValue';
    String response = await firstAtSignConnection
        .sendRequestToServer('update:@🦄:emoji.name$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB
    response = await firstAtSignConnection
        .sendRequestToServer('llookup:@🦄:emoji.name$firstAtSign');
    expect(response, contains('data:$value'));
  });

  test('update-llookup for ttl ', () async {
    ///UPDATE VERB
    var value = '$lastValue seconds';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttl:3000:$firstAtSign:offer-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP:META verb
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:meta:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('"ttl":3000'));

    ///LLOOKUP VERB - Before 3 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 3 seconds
    await Future.delayed(Duration(seconds: 3));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:offer-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));
  });

  test('update-llookup for ttb ', () async {
    ///UPDATE VERB
    var value = '3289$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttb:2000:$firstAtSign:auth-code-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 2 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));

    /// Wait for 2 seconds before proceeding
    await Future.delayed(Duration(seconds: 2));

    ///LLOOKUP VERB - After 2 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLookup:META FOR TTB
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:meta:$firstAtSign:auth-code-$uniqueId$firstAtSign');
    expect(response, contains('"ttb":2000'));
  });

  test('update-llookup for ttl and ttb together', () async {
    ///UPDATE VERB
    var value = '1122$lastValue';
    String response = await firstAtSignConnection.sendRequestToServer(
        'update:ttl:4000:ttb:2000:$firstAtSign:login-code-$uniqueId$firstAtSign $value');
    assert(
        (!response.contains('Invalid syntax')) && (!response.contains('null')));

    ///LLOOKUP VERB - Before 3 seconds
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));

    ///LLOOKUP VERB - After 4 seconds ttb time
    await Future.delayed(Duration(seconds: 2));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:$value'));

    ///LLOOKUP VERB - After 4 seconds ttl time
    await Future.delayed(Duration(seconds: 4));
    response = await firstAtSignConnection.sendRequestToServer(
        'llookup:$firstAtSign:login-code-$uniqueId$firstAtSign');
    expect(response, contains('data:null'));
  });

  tearDownAll(() async {
    await firstAtSignConnection.close();
  });
}
