import 'package:args/args.dart';
import 'package:at_secondary/src/arg_utils.dart';
import 'package:test/test.dart';

void main() {
  group('Commandline parser tests', () {
    test('parse all the arguments', () {
      var arguments = [
        '--at_sign',
        '@alice',
        '--server_port',
        '6400',
        '--shared_secret',
        'cde445tsfg'
      ];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('at_sign'), true);
      expect(results.wasParsed('server_port'), true);
      expect(results.arguments[0], '--at_sign');
      expect(results.arguments[1], '@alice');
      expect(results.arguments[2], '--server_port');
      expect(results.arguments[3], '6400');
      expect(results.arguments[4], '--shared_secret');
      expect(results.arguments[5], 'cde445tsfg');
    });

    test('parse arguments using abbreviation', () {
      var arguments = ['-a', '@alice', '-p', '6400', '-s', 'cde445tsfg'];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('at_sign'), true);
      expect(results.wasParsed('server_port'), true);
      expect(results.arguments[0], '-a');
      expect(results.arguments[1], '@alice');
      expect(results.arguments[2], '-p');
      expect(results.arguments[3], '6400');
    });

    test('send null as arguments', () {
      var args;
      expect(() => CommandLineParser().getParserResults(args),
          throwsA(predicate((e) => e is ArgParserException)));
    });

    test('Miss one argument', () {
      var arguments = ['--server_port', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((e) => e is ArgParserException)));
    });

    test('invalid argument name', () {
      var arguments = ['--at_signnn', 'alice', '--server_port', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((e) => e is ArgParserException)));
    });

    test('invalid abbreviation', () {
      var arguments = ['--at_sign', 'alice', '--s', '6400'];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((e) => e is ArgParserException)));
    });
  });
}
