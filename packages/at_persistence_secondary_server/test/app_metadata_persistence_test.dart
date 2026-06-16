// Round-trip tests for the AtMetaData.appMetadata persistence field:
// commons-Metadata conversions, JSON round-trip (Map and base64 wire
// forms), Hive box round-trip through AtMetaDataAdapter, and
// backward-compatible reads of records written before the field
// existed (26-field format).
//
// Isolation: file-scoped keystore via setUpAll/tearDownAll, matching
// at_metadata_test.dart.

import 'dart:io';

// ignore_for_file: implementation_imports
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/hive.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/hive_impl.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

void main() {
  const atSign = '@alice';
  var storageDir = '${Directory.current.path}/test/hive';

  AppMetadata sampleAppMetadata() => AppMetadata(
        providerId: 'acme_provider',
        additional: {
          'keyId': 'k-123',
          'epoch': 42,
          'rotated': true,
        },
      );

  group('AtMetaData <-> commons Metadata conversions', () {
    test('fromCommonsMetadata carries appMetadata through', () {
      final commons = Metadata()..appMetadata = sampleAppMetadata();
      final atMetaData = AtMetaData.fromCommonsMetadata(commons, atSign);
      expect(atMetaData.appMetadata, sampleAppMetadata());
    });

    test('toCommonsMetadata carries appMetadata back', () {
      final atMetaData = AtMetaData()..appMetadata = sampleAppMetadata();
      expect(atMetaData.toCommonsMetadata().appMetadata, sampleAppMetadata());
    });

    test('null appMetadata stays null in both directions', () {
      final commons = Metadata();
      final atMetaData = AtMetaData.fromCommonsMetadata(commons, atSign);
      expect(atMetaData.appMetadata, isNull);
      expect(atMetaData.toCommonsMetadata().appMetadata, isNull);
    });
  });

  group('AtMetaData JSON round-trip', () {
    test('toJson emits a Map; fromJson restores equality', () {
      final original = AtMetaData()
        ..createdAt = DateTime.now().toUtcMillisecondsPrecision()
        ..updatedAt = DateTime.now().toUtcMillisecondsPrecision()
        ..appMetadata = sampleAppMetadata();
      final json = original.toJson();
      expect(json[AtConstants.appMetadata], isA<Map>());
      expect(AtMetaData.fromJson(json).appMetadata, sampleAppMetadata());
    });

    test('fromJson also accepts the base64 wire form', () {
      final json = (AtMetaData()
            ..createdAt = DateTime.now().toUtcMillisecondsPrecision()
            ..updatedAt = DateTime.now().toUtcMillisecondsPrecision())
          .toJson();
      json[AtConstants.appMetadata] =
          Metadata.encodeAppMetadata(sampleAppMetadata());
      expect(AtMetaData.fromJson(json).appMetadata, sampleAppMetadata());
    });
  });

  group('Hive keystore round-trip', () {
    late HiveAtKeyValueStore keyStore;
    setUpAll(() async {
      keyStore = await setUpTestKeyStore(atSign, storageDir: storageDir);
    });
    tearDownAll(
        () async => await tearDownTestPersistence(storageDir: storageDir));

    test('appMetadata survives put + get through the adapter', () async {
      const key = 'app_meta_roundtrip.test$atSign';
      final atData = AtData()
        ..data = 'value'
        ..metaData = (AtMetaData()..appMetadata = sampleAppMetadata());
      await keyStore.put(key, atData);

      final readBack = await keyStore.get(key);
      expect(readBack!.metaData!.appMetadata, sampleAppMetadata());
    });

    test('appMetadata survives putMeta + getMeta', () async {
      const key = 'app_meta_putmeta.test$atSign';
      await keyStore.put(key, AtData()..data = 'value');
      await keyStore.putMeta(
          key, AtMetaData()..appMetadata = sampleAppMetadata());
      final meta = await keyStore.getMeta(key);
      expect(meta!.appMetadata, sampleAppMetadata());
    });
  });

  group('AtMetaDataAdapter binary format', () {
    test('write/read round-trip preserves appMetadata', () {
      final adapter = AtMetaDataAdapter();
      final original = AtMetaData()
        ..createdBy = atSign
        ..ttl = 1000
        ..appMetadata = sampleAppMetadata();

      final writer = BinaryWriterImpl(HiveImpl());
      adapter.write(writer, original);
      final readBack =
          adapter.read(BinaryReaderImpl(writer.toBytes(), HiveImpl()));

      expect(readBack.appMetadata, sampleAppMetadata());
      expect(readBack.ttl, 1000);
      expect(readBack.createdBy, atSign);
    });

    test(
        'a record written in the pre-appMetadata 26-field format reads '
        'back with appMetadata null and other fields intact', () {
      // Fixture: byte-for-byte what the adapter wrote before field 26
      // existed (field indexes 0-25, count byte 26). pubKeyHash is
      // left null so the fixture needs no nested adapter.
      final createdAt = DateTime.now().toUtcMillisecondsPrecision();
      final writer = BinaryWriterImpl(HiveImpl());
      writer.writeByte(26);
      final oldFields = <dynamic>[
        'creator', // 0 createdBy
        'updater', // 1 updatedBy
        createdAt, // 2 createdAt
        createdAt, // 3 updatedAt
        null, // 4 expiresAt
        'active', // 5 status
        3, // 6 version
        null, // 7 ttb
        60000, // 8 ttl
        null, // 9 ttr
        null, // 10 refreshAt
        null, // 11 isCascade
        null, // 12 availableAt
        false, // 13 isBinary
        true, // 14 isEncrypted
        null, // 15 dataSignature
        'sharedKeyEnc', // 16 sharedKeyEnc
        null, // 17 pubKeyCS
        null, // 18 encoding
        'encKeyName', // 19 encKeyName
        null, // 20 encAlgo
        null, // 21 ivNonce
        null, // 22 skeEncKeyName
        null, // 23 skeEncAlgo
        null, // 24 pubKeyHash
        true, // 25 immutable
      ];
      for (var i = 0; i < oldFields.length; i++) {
        writer.writeByte(i);
        writer.write(oldFields[i]);
      }

      final readBack = AtMetaDataAdapter()
          .read(BinaryReaderImpl(writer.toBytes(), HiveImpl()));

      expect(readBack.appMetadata, isNull);
      expect(readBack.createdBy, 'creator');
      expect(readBack.updatedBy, 'updater');
      expect(readBack.createdAt, createdAt);
      expect(readBack.status, 'active');
      expect(readBack.version, 3);
      expect(readBack.ttl, 60000);
      expect(readBack.isBinary, false);
      expect(readBack.isEncrypted, true);
      expect(readBack.sharedKeyEnc, 'sharedKeyEnc');
      expect(readBack.encKeyName, 'encKeyName');
      expect(readBack.immutable, true);
    });
  });
}
