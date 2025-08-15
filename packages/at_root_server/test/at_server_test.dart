import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_commons/at_commons.dart';
import 'package:test/test.dart';
import 'package:at_root_server/src/server/at_root_server_impl.dart';

void main() {
  late RootServerImpl rootServerImpl;
  late AtRootServerContext atRootServerContext;
  setUp(() {
    rootServerImpl = RootServerImpl();
    atRootServerContext = AtRootServerContext();
    rootServerImpl.setServerContext(atRootServerContext);
  });
  group('Root server tests for AtServerException', () {
    test('root server port not set - AtServerException', () {
      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException &&
              e.message == 'server port is not set')));
    });

    test('Redis host not set - AtServerException', () {
      atRootServerContext.port = 12345;
      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException && e.message == 'redis host is not set')));
    });

    test('Redis port is not set - AtServerException', () {
      atRootServerContext.port = 12345;
      atRootServerContext.redisServerHost = 'localhost';

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException && e.message == 'redis port is not set')));
    });

    test('Redis auth is not set - AtServerException', () {
      atRootServerContext.port = 12345;
      atRootServerContext.redisServerHost = 'localhost';
      atRootServerContext.redisServerPort = 6379;

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException && e.message == 'redis auth is not set')));
    });
  });
}
