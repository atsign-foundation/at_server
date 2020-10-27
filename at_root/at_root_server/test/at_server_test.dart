import 'package:at_root_server/src/server/server_context.dart';
import 'package:at_commons/at_commons.dart';
import 'package:test/test.dart';
import 'package:at_root_server/src/server/at_root_server_impl.dart';

void main() {
  group('Root server tests for AtServerException', () {
    test('Redis host not set - AtServerException', () {
      var rootServerImpl = RootServerImpl();
      var atRootServerContext = AtRootServerContext();
      rootServerImpl.setServerContext(atRootServerContext);

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((e) =>
              e is AtServerException && e.message == 'redis host is not set')));
    });

    test('Redis port is not set - AtServerException', () {
      var rootServerImpl = RootServerImpl();
      var atRootServerContext = AtRootServerContext();
      atRootServerContext.redisServerHost = 'localhost';
      rootServerImpl.setServerContext(atRootServerContext);

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((e) =>
              e is AtServerException && e.message == 'redis port is not set')));
    });

    test('Redis auth is not set - AtServerException', () {
      var rootServerImpl = RootServerImpl();
      var atRootServerContext = AtRootServerContext();
      atRootServerContext.redisServerHost = 'localhost';
      atRootServerContext.redisServerPort = 6379;
      rootServerImpl.setServerContext(atRootServerContext);

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((e) =>
              e is AtServerException && e.message == 'redis auth is not set')));
    });

    test('root server port not set - AtServerException', () {
      var rootServerImpl = RootServerImpl();
      var atRootServerContext = AtRootServerContext();
      //Setting server port to null
      atRootServerContext.port = null;
      rootServerImpl.setServerContext(atRootServerContext);

      expect(
          () => rootServerImpl.start(),
          throwsA(predicate((e) =>
              e is AtServerException &&
              e.message == 'server port is not set')));
    });
  });
}
