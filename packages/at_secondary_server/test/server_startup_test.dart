import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/at_security_context_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:at_secondary/src/verb/executor/default_verb_executor.dart';
import 'package:at_secondary/src/verb/manager/verb_handler_manager.dart';
import 'package:at_commons/at_commons.dart';
import 'package:test/test.dart';

void main() {
  group('group of server startup test', () {
    test('server context not set', () {
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      expect(
          () => secondaryServerInstance.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException &&
              e.message == 'Server context is not initialized')));
    });

    test('verb executor not set', () {
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      var context = AtSecondaryContext();
      secondaryServerInstance.setServerContext(context);
      expect(
          () => secondaryServerInstance.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException &&
              e.message == 'Verb executor is not initialized')));
    });

    // precondition. useTLS is set to true in config file
    test('security context not set', () {
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      var context = AtSecondaryContext();
      secondaryServerInstance.setServerContext(context);
      secondaryServerInstance.setExecutor(DefaultVerbExecutor());
      expect(
          () => secondaryServerInstance.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException &&
              e.message == 'Security context is not set')));
    });

    /* test('keystore not initialized', () {
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      var context = AtSecondaryContext();
      context.currentAtSign = '@alice';
      secondaryServerInstance.setServerContext(context);
      secondaryServerInstance.setExecutor(DefaultVerbExecutor());
      context.securityContext = AtSecurityContextImpl();
      expect(
          () => secondaryServerInstance.start(),
          throwsA(predicate((e) =>
              e is AtServerException &&
              e.message == 'Secondary keystore is not initialized')));
    });*/

    test('User atSign is not set', () {
      var secondaryServerInstance = AtSecondaryServerImpl.getInstance();
      var context = AtSecondaryContext();
      secondaryServerInstance.setServerContext(context);
      secondaryServerInstance.setExecutor(DefaultVerbExecutor());
      context.securityContext = AtSecurityContextImpl();
      context.isKeyStoreInitialized = true;
      expect(
          () => secondaryServerInstance.start(),
          throwsA(predicate((dynamic e) =>
              e is AtServerException &&
              e.message == 'User atSign is not set')));
    });
  });
}
