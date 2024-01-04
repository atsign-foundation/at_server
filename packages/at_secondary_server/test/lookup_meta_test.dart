import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:test/test.dart';
import 'package:at_secondary/src/utils/handler_util.dart';
import 'package:at_commons/at_commons.dart';
import 'package:mocktail/mocktail.dart';

class MockSecondaryKeyStore extends Mock implements SecondaryKeyStore {}

class MockOutboundClientManager extends Mock implements OutboundClientManager {}

class MockAtCacheManager extends Mock implements AtCacheManager {}

void main() {
  SecondaryKeyStore mockKeyStore = MockSecondaryKeyStore();
  OutboundClientManager mockOutboundClientManager = MockOutboundClientManager();
  AtCacheManager mockAtCacheManager = MockAtCacheManager();

  group('A group of lookup meta verb tests', () {
    test('test lookup meta', () {
      var verb = Lookup();
      var command = 'lookup:meta:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
      expect(paramsMap[AtConstants.operation], 'meta');
    });

    test('test lookup all', () {
      var verb = Lookup();
      var command = 'lookup:all:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
      expect(paramsMap[AtConstants.operation], 'all');
    });

    test('test lookup data', () {
      var verb = Lookup();
      var command = 'lookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AtConstants.atKey], 'email');
      expect(paramsMap[AtConstants.atSign], 'colin');
      expect(paramsMap[AtConstants.operation], null);
    });

    test('test lookup meta command accept test without operation', () {
      var command = 'lookup:location@alice';
      var handler = LookupVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup meta command accept test for meta', () {
      var command = 'lookup:meta:location@alice';
      var handler = LookupVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup meta command accept test for all', () {
      var command = 'lookup:all:location@alice';
      var handler = LookupVerbHandler(
          mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      print('result : $result');
      expect(result, true);
    });

    test('test lookup key- no atSign', () {
      var verb = Lookup();
      var command = 'lookup:meta:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with out atSign', () {
      var verb = Lookup();
      var command = 'lookup:meta:location@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with out atSign for al', () {
      var verb = Lookup();
      var command = 'lookup:all:email@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup with emoji-invalid syntax', () {
      var verb = Lookup();
      var command = 'lookup:meta:email🐼';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test lookup key- invalid keyword', () {
      var verb = Lookup();
      var command = 'lokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
