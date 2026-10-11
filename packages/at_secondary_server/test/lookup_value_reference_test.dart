import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// How a lookup from another atServer resolves a value reference.
void main() {
  final Atsign bob = '@bob'.toAtsign();

  late LookupVerbHandler handler;

  setUpAll(() async => await verbTestsSetUpAll());

  setUp(() async {
    await verbTestsSetUp();
    handler = LookupVerbHandler(
        keyValueStore, mockOutboundClientManager, cacheManager, enMgr,
        accessLog: atAccessLog);
    inboundConnection.metadata
      ..isAuthenticated = false
      ..isPolAuthenticated = true
      ..fromAtSign = bob;
    await keyValueStore.put('@bob:card.chat$alice',
        AtData()..data = 'atsign://photo.photos$alice');
  });

  tearDown(() async => await verbTestsTearDown());

  Future<String?> lookUpCard() async =>
      (await handler.processInternal('lookup:card.chat@alice', inboundConnection))
          .data;

  group('Given a key shared with @bob whose value refers to another key', () {
    test('when only the copy shared with @bob is held, then it answers that',
        () async {
      await keyValueStore.put(
          '@bob:photo.photos$alice', AtData()..data = 'shared');
      expect(await lookUpCard(), 'shared');
    });

    test('when only the public copy is held, then it answers that', () async {
      await keyValueStore.put(
          'public:photo.photos$alice', AtData()..data = 'public');
      expect(await lookUpCard(), 'public');
    });

    test(
        'when both copies are held, then it answers the copy shared with'
        ' @bob', () async {
      await keyValueStore.put(
          '@bob:photo.photos$alice', AtData()..data = 'shared');
      await keyValueStore.put(
          'public:photo.photos$alice', AtData()..data = 'public');
      expect(await lookUpCard(), 'shared');
    });

    test('when neither copy is held, then it answers null', () async {
      expect(await lookUpCard(), isNull);
    });
  });
}
