
import 'dart:convert';
import 'dart:math';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

final Random random = Random();

Map decodeResponse(String sentToClient) {
  return jsonDecode(sentToClient.substring('data:'.length, sentToClient.indexOf('\n')));
}

Future<AtData> createRandomKeyStoreEntry(String atSign, String keyName, SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore) async {
  AtData entry = createRandomAtData(atSign);
  await secondaryKeyStore.put(keyName, entry);
  return (await secondaryKeyStore.get(keyName))!;
}

AtData createRandomAtData(String atSign) {
  AtData atData = AtData();
  atData.data = createRandomString(100);
  atData.metaData = createRandomAtMetaData(atSign);
  return atData;
}

AtMetaData createRandomAtMetaData(String atSign) {
  AtMetaData md = AtMetaData();
  DateTime now = DateTime.now().toUtc();
  md.createdBy = atSign;
  md.updatedBy = atSign;
  md.createdAt = now;
  md.updatedAt = now;
  md.isEncrypted = createRandomNullableBoolean();
  md.isBinary = createRandomNullableBoolean();
  md.encoding = createRandomString(5);
  md.pubKeyCS = createRandomString(5);
  md.sharedKeyEnc = createRandomString(10);
  md.dataSignature = createRandomString(7);
  md.isCascade = createRandomNullableBoolean();
  md.ttl = createRandomNullablePositiveInt();
  md.ttb = createRandomNullablePositiveInt();
  md.ttr = createRandomNullablePositiveInt();
  return md;
}

int? createRandomNullablePositiveInt({int maxInclusive = 100000}) {
  // We'll make it null 50% of the time
  if (random.nextInt(2) == 0) {
    return null;
  }
  // We'll make it zero 10% of the time (1/5th of the remaining 50%)
  if (random.nextInt(5) == 0) {
    return 0;
  }
  return random.nextInt(maxInclusive) + 1;
}

bool? createRandomNullableBoolean() {
  int i = random.nextInt(3);
  if (i == 0) return null;
  if (i == 1) return false;
  return true;
}

const String characters = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_';
String createRandomString(int length) {
  return String.fromCharCodes(Iterable.generate(length, (index) => characters.codeUnitAt(random.nextInt(characters.length))));
}
