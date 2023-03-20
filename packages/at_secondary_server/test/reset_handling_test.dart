import 'dart:convert';

import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_utils/at_logger.dart';
import 'package:crypton/crypton.dart';
import 'package:test/test.dart';
import 'package:mocktail/mocktail.dart';

import 'test_utils.dart';

// the atSign for the server for these tests is @alice - see test_utils.dart
void main() {
  AtSignLogger.root_level = 'WARNING';
  group('Handling resets of other atSigns', () {
    late LookupVerbHandler lookupVerbHandler;

    var sharedEncryptionKeyName = 'shared_key.bob@alice';
    var sharedEncryptionKeyData = AtData()..metaData=(AtMetaData()..ttr=-1)..data='alice_shared_key_for_bob';

    setUpAll(() async {
      await verbTestsSetUpAll();
    });

    setUp(() async {
      await verbTestsSetUp();
      lookupVerbHandler = LookupVerbHandler(secondaryKeyStore, mockOutboundClientManager, cacheManager);
    });

    tearDown(() async {
      await verbTestsTearDown();
    });

    test('lookup some bob key, bob public encryption key unchanged', () async {
      // Given
      //   * a cached:public:publickey@bob in the cache
      //   * a shared_key.bob@alice in the keystore
      // When
      //   * @alice client to this @alice server does a remote lookup of a non-existent key from @bob server
      //   * or does a remote lookup of a @bob key that exists
      // Then
      //   * a KeyNotFoundException is thrown, or not, as expected, and in both cases
      //   * publickey@bob has been fetched as part of OutboundClient creation / connection
      //   * cached:public:publickey@bob is unchanged (updatedAt should not have changed)
      //   * shared_key.bob@alice is unchanged
      await cacheManager.put(cachedBobsPublicKeyName, bobOriginalPublicKeyAtData);
      await secondaryKeyStore.put(sharedEncryptionKeyName, sharedEncryptionKeyData);

      inboundConnection.metadata.isAuthenticated = true;

      var nonExistentKeyName = 'no.such.key.some_app@bob';
      when(() => mockOutboundConnection.write('lookup:all:$nonExistentKeyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn('error:{"errorCode":"AT0015","errorDescription":"$nonExistentKeyName does not exist"}\n$alice@'.codeUnits);
      });
      await expectLater(
          lookupVerbHandler.process('lookup:all:$nonExistentKeyName', inboundConnection),
          throwsA(isA<KeyNotFoundException>()));
      AtData cachedBobPublicKeyData = (await cacheManager.get(cachedBobsPublicKeyName, applyMetadataRules: true))!;
      expect(cachedBobPublicKeyData.data, bobOriginalPublicKeyAtData.data);
      expect(cachedBobPublicKeyData.metaData!.updatedAt!.millisecondsSinceEpoch, bobOriginalPublicKeyAtData.metaData!.updatedAt!.millisecondsSinceEpoch);
      expect(secondaryKeyStore.isKeyExists(sharedEncryptionKeyName), true);

      var existsKeyName = 'some.key.some_app@bob';
      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$existsKeyName')!;
      when(() => mockOutboundConnection.write('lookup:all:$existsKeyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });
      await lookupVerbHandler.process('lookup:all:$existsKeyName', inboundConnection);
      cachedBobPublicKeyData = (await cacheManager.get(cachedBobsPublicKeyName, applyMetadataRules: true))!;
      expect(cachedBobPublicKeyData.data, bobOriginalPublicKeyAtData.data);
      expect(cachedBobPublicKeyData.metaData!.updatedAt!.millisecondsSinceEpoch, bobOriginalPublicKeyAtData.metaData!.updatedAt!.millisecondsSinceEpoch);
      expect(cachedBobPublicKeyData.metaData!.createdAt!.millisecondsSinceEpoch, bobOriginalPublicKeyAtData.metaData!.createdAt!.millisecondsSinceEpoch);
      expect(secondaryKeyStore.isKeyExists(sharedEncryptionKeyName), true);
    });

    test('bob public encryption key changed, no current shared_key.bob@alice', () async {
      // Given
      //   * a cached:public:publickey@bob in the cache
      // When
      //   * @alice client to this @alice server does a remote lookup to @bob server
      // Then
      //   * a new value for publickey@bob has been fetched as part of OutboundClient creation / connection
      //   * cached:public:publickey@bob has been changed
      await secondaryKeyStore.put(cachedBobsPublicKeyName, bobOriginalPublicKeyAtData);

      AtData originalCachedBobPublicKeyData = (await secondaryKeyStore.get(cachedBobsPublicKeyName))!;

      inboundConnection.metadata.isAuthenticated = true;

      var existsKeyName = 'some.key.some_app@bob';
      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$existsKeyName')!;
      when(() => mockOutboundConnection.write('lookup:all:$existsKeyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      await Future.delayed(Duration(milliseconds: 100));

      var bobNewPublicKeypair = RSAKeypair.fromRandom();
      late AtData bobNewPublicKeyAtData;
      late String bobNewPublicKeyAsJson;
      DateTime now = DateTime.now().toUtcMillisecondsPrecision();
      bobNewPublicKeyAtData = AtData();
      bobNewPublicKeyAtData.data = bobNewPublicKeypair.publicKey.toString();
      bobNewPublicKeyAtData.metaData = AtMetaData()
        ..ttr=-1
        ..createdAt=now
        ..updatedAt=now;
      bobNewPublicKeyAsJson = SecondaryUtil.prepareResponseData('all', bobNewPublicKeyAtData, key: 'public:publickey$bob')!;
      bobNewPublicKeyAtData = AtData().fromJson(jsonDecode(bobNewPublicKeyAsJson));
      when(() => mockOutboundConnection.write('lookup:all:publickey@bob\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobNewPublicKeyAsJson\n$alice@".codeUnits);
      });

      print ('orig ${bobOriginalPublicKeyAtData.metaData!.createdAt} new ${bobNewPublicKeyAtData.metaData!.createdAt}');

      await lookupVerbHandler.process('lookup:all:$existsKeyName', inboundConnection);
      AtData newCachedBobPublicKeyData = (await cacheManager.get(cachedBobsPublicKeyName, applyMetadataRules: true))!;
      expect(originalCachedBobPublicKeyData.data == bobOriginalPublicKeyAtData.data, true);
      expect(newCachedBobPublicKeyData.data != bobOriginalPublicKeyAtData.data, true);
      expect(newCachedBobPublicKeyData.data == bobNewPublicKeyAtData.data, true);
      expect(
          originalCachedBobPublicKeyData.metaData!.createdAt!.millisecondsSinceEpoch <
              bobNewPublicKeyAtData.metaData!.createdAt!.millisecondsSinceEpoch,
          true);
      expect(
          newCachedBobPublicKeyData.metaData!.createdAt!.millisecondsSinceEpoch >
              bobNewPublicKeyAtData.metaData!.createdAt!.millisecondsSinceEpoch,
          true);
    });

    test('bob public encryption key changed, shared_key.bob@alice removed but preserved', () async {
      // Given
      //   * a cached:public:publickey@bob in the cache
      //   * a shared_key.bob@alice in the keystore
      // When
      //   * @alice client to this @alice server does a remote lookup to @bob server
      // Then
      //   * a new value for publickey@bob has been fetched as part of OutboundClient creation / connection
      //   * cached:public:publickey@bob has been changed
      //   * shared_key.bob@alice no longer exists
      //   * but there is a copy of it called shared_key.bob.until.<millis>@alice
      await secondaryKeyStore.put(cachedBobsPublicKeyName, bobOriginalPublicKeyAtData);
      await secondaryKeyStore.put(sharedEncryptionKeyName, sharedEncryptionKeyData);

      AtData originalCachedBobPublicKeyData = (await secondaryKeyStore.get(cachedBobsPublicKeyName))!;

      inboundConnection.metadata.isAuthenticated = true;

      var existsKeyName = 'some.key.some_app@bob';
      AtData bobData = createRandomAtData(bob);
      bobData.metaData!.ttr = 10;
      bobData.metaData!.ttb = null;
      bobData.metaData!.ttl = null;
      String bobDataAsJsonWithKey = SecondaryUtil.prepareResponseData('all', bobData, key: '$alice:$existsKeyName')!;
      when(() => mockOutboundConnection.write('lookup:all:$existsKeyName\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobDataAsJsonWithKey\n$alice@".codeUnits);
      });

      await Future.delayed(Duration(milliseconds: 100));

      var bobNewPublicKeypair = RSAKeypair.fromRandom();
      late AtData bobNewPublicKeyAtData;
      late String bobNewPublicKeyAsJson;
      DateTime now = DateTime.now().toUtcMillisecondsPrecision();
      bobNewPublicKeyAtData = AtData();
      bobNewPublicKeyAtData.data = bobNewPublicKeypair.publicKey.toString();
      bobNewPublicKeyAtData.metaData = AtMetaData()
        ..ttr=-1
        ..createdAt=now
        ..updatedAt=now;
      bobNewPublicKeyAsJson = SecondaryUtil.prepareResponseData('all', bobNewPublicKeyAtData, key: 'public:publickey$bob')!;
      bobNewPublicKeyAtData = AtData().fromJson(jsonDecode(bobNewPublicKeyAsJson));
      when(() => mockOutboundConnection.write('lookup:all:publickey@bob\n'))
          .thenAnswer((Invocation invocation) async {
        socketOnDataFn("data:$bobNewPublicKeyAsJson\n$alice@".codeUnits);
      });

      expect(secondaryKeyStore.isKeyExists(sharedEncryptionKeyName), true);

      await lookupVerbHandler.process('lookup:all:$existsKeyName', inboundConnection);

      AtData newCachedBobPublicKeyData = (await cacheManager.get(cachedBobsPublicKeyName, applyMetadataRules: true))!;

      expect(originalCachedBobPublicKeyData.data == bobOriginalPublicKeyAtData.data, true);
      expect(newCachedBobPublicKeyData.data != bobOriginalPublicKeyAtData.data, true);
      expect(newCachedBobPublicKeyData.data == bobNewPublicKeyAtData.data, true);
      expect(originalCachedBobPublicKeyData.metaData!.createdAt!.millisecondsSinceEpoch < bobNewPublicKeyAtData.metaData!.createdAt!.millisecondsSinceEpoch, true);
      expect(newCachedBobPublicKeyData.metaData!.createdAt!.millisecondsSinceEpoch > bobNewPublicKeyAtData.metaData!.createdAt!.millisecondsSinceEpoch, true);

      expect(secondaryKeyStore.isKeyExists(sharedEncryptionKeyName), false);

      List<String> matches = secondaryKeyStore.getKeys(regex: r'shared_key\.bob');
      expect(matches.contains(sharedEncryptionKeyName), false);
      bool found = false;
      for (String mkn in matches) {
        print ("regex matched $mkn");
        if (mkn.startsWith('shared_key.bob.until')) {
          found = true;
          print ("Found match - $mkn");
        }
      }
      expect (found, true);
    });
  });
}
