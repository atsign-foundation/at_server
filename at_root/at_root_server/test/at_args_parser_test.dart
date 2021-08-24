import 'package:args/args.dart';
import 'package:test/test.dart';
import 'package:at_root_server/src/command_line_utils.dart';

void main() {
  group('Commandline parser tests', () {
    test('parse all the arguments', () {
      var arguments = [
        '--redis_host',
        'localhost',
        '--redis_port',
        '6379',
        '--redis_auth',
        'mypassword'
      ];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('redis_host'), true);
      expect(results.wasParsed('redis_port'), true);
      expect(results.wasParsed('redis_auth'), true);
      expect(results.arguments[0], '--redis_host');
      expect(results.arguments[1], 'localhost');
      expect(results.arguments[2], '--redis_port');
      expect(results.arguments[3], '6379');
      expect(results.arguments[4], '--redis_auth');
      expect(results.arguments[5], 'mypassword');
    });

    test('parse all the arguments with abbrevation', () {
      var arguments = ['-h', 'localhost', '-p', '6379', '-a', 'mypassword'];
      var results = CommandLineParser().getParserResults(arguments);
      expect(results.wasParsed('redis_host'), true);
      expect(results.wasParsed('redis_port'), true);
      expect(results.wasParsed('redis_auth'), true);
      expect(results.arguments[0], '-h');
      expect(results.arguments[1], 'localhost');
      expect(results.arguments[2], '-p');
      expect(results.arguments[3], '6379');
      expect(results.arguments[4], '-a');
      expect(results.arguments[5], 'mypassword');
    });

    test('send null as arguments', () async {
      List<String> arguments = [];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });

    test('Miss one argument', () async {
      List<String> arguments = [
        '--redis_host',
        'localhost',
        '--redis_port',
        '6379'
      ];
      expect(() => CommandLineParser().getParserResults(arguments),
          throwsA(predicate((dynamic e) => e is ArgParserException)));
    });
  });
}
