import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/caching/cache_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
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

  group('A group of proxy_lookup verb tests', () {
    test('test proxy_lookup key-value', () {
      var verb = ProxyLookup();
      var command = 'plookup:email@colin';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'email');
      expect(paramsMap[AT_SIGN], 'colin');
    });

    test('test proxy_lookup getVerb', () {
      var handler = ProxyLookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var verb = handler.getVerb();
      expect(verb is ProxyLookup, true);
    });

    test('test proxy_lookup command accept test', () {
      var command = 'plookup:location@alice';
      var handler = ProxyLookupVerbHandler(mockKeyStore, mockOutboundClientManager, mockAtCacheManager);
      var result = handler.accept(command);
      expect(result, true);
    });

    test('test proxy_lookup regex', () {
      var verb = ProxyLookup();
      var command = 'plookup:location@🦄';
      var regex = verb.syntax();
      var paramsMap = getVerbParam(regex, command);
      expect(paramsMap[AT_KEY], 'location');
      expect(paramsMap[AT_SIGN], '🦄');
    });

    test('test proxy_lookup with invalid atsign', () {
      var verb = ProxyLookup();
      var command = 'plookup:location@alice@@@';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test proxy_lookup key- no atSign', () {
      var verb = ProxyLookup();
      var command = 'plookup:location';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });

    test('test proxy_lookup key invalid keyword', () {
      var verb = ProxyLookup();
      var command = 'plokup:location@alice';
      var regex = verb.syntax();
      expect(
          () => getVerbParam(regex, command),
          throwsA(predicate((dynamic e) =>
              e is InvalidSyntaxException && e.message == 'Syntax Exception')));
    });
  });
}
