import 'package:args/args.dart';
import 'package:at_secondary/src/arg_utils.dart';
import 'package:at_secondary/src/server/bootstrapper.dart';
import 'package:test/test.dart';
import 'test_utils.dart';

void main() {
  group('Commandline parser tests', () {
    test('parse all the arguments except for optional flags', () {
      var arguments = [
        '--at_sign',
        alice,
        '--server_port',
        '6400',
        '--shared_secret',
        'cde445tsfg'
      ];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('at_sign'), true);
      expect(results.wasParsed('server_port'), true);
      expect(results.arguments[0], '--at_sign');
      expect(results.arguments[1], alice);
      expect(results.arguments[2], '--server_port');
      expect(results.arguments[3], '6400');
      expect(results.arguments[4], '--shared_secret');
      expect(results.arguments[5], 'cde445tsfg');

      expect(results['training'], false);
      expect(results['telemetry-endpoint'], '');
    });

    test('parse the telemetry endpoint', () {
      var arguments = [
        '--at_sign',
        alice,
        '--server_port',
        '6400',
        '--shared_secret',
        'cde445tsfg',
        '--telemetry-endpoint',
        'collector.example.com:443'
      ];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results['telemetry-endpoint'], 'collector.example.com:443');
    });

    test('parse all the arguments including optional flags', () {
      var arguments = [
        '--at_sign',
        alice,
        '--server_port',
        '6400',
        '--shared_secret',
        'cde445tsfg',
        '--training'
      ];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('at_sign'), true);
      expect(results.wasParsed('server_port'), true);
      expect(results.arguments[0], '--at_sign');
      expect(results.arguments[1], alice);
      expect(results.arguments[2], '--server_port');
      expect(results.arguments[3], '6400');
      expect(results.arguments[4], '--shared_secret');
      expect(results.arguments[5], 'cde445tsfg');
      expect(results.arguments[6], '--training');

      expect(results['training'], true);
    });

    test('parse arguments using abbreviation', () {
      var arguments = ['-a', alice, '-p', '6400', '-s', 'cde445tsfg'];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('at_sign'), true);
      expect(results.wasParsed('server_port'), true);
      expect(results.arguments[0], '-a');
      expect(results.arguments[1], alice);
      expect(results.arguments[2], '-p');
      expect(results.arguments[3], '6400');
    });

    test('send null as arguments', () {
      List<String>? args;
      expect(() => CommandLineParser().getParserResults(args),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });

    test('Miss one argument', () {
      var arguments = ['--server_port', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });

    test('invalid argument name', () {
      var arguments = ['--at_signnn', 'alice', '--server_port', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });

    test('invalid flag name', () {
      var arguments = [
        '--at_sign',
        'alice',
        '--server_port',
        '6400',
        '--ttraining'
      ];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });

    test('invalid abbreviation', () {
      var arguments = ['--at_sign', 'alice', '--s', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });
  });

  group('Telemetry endpoint tests', () {
    const List<String> required = <String>[
      '--at_sign',
      '@alice',
      '--server_port',
      '6400',
      '--shared_secret',
      'cde445tsfg'
    ];
    const Map<String, String> environment = <String, String>{
      'AT_TELEMETRY_ENDPOINT': 'env.example.com:443'
    };

    String? endpointFor(List<String> extra, Map<String, String> environment) {
      final ArgResults results =
          CommandLineParser().getParserResults(<String>[...required, ...extra]);
      return SecondaryServerBootStrapper.telemetryEndpointFrom(
          results, environment);
    }

    test('the flag wins over the environment variable', () {
      expect(
          endpointFor(
              <String>['--telemetry-endpoint', 'flag.example.com:443'],
              environment),
          'flag.example.com:443');
    });

    test('the environment variable is used when the flag is absent', () {
      expect(endpointFor(<String>[], environment), 'env.example.com:443');
    });

    test('an empty flag turns telemetry off even if the variable is set', () {
      expect(
          endpointFor(<String>['--telemetry-endpoint', ''], environment), null);
    });

    test('telemetry is off when neither is set', () {
      expect(endpointFor(<String>[], <String, String>{}), null);
    });
  });
}
