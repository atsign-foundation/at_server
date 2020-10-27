import 'package:args/args.dart';
import 'package:at_utils/at_logger.dart';

/// A class for taking a list of raw command line arguments and parsing out
/// options and flags from them.
class CommandLineParser {
  var logger = AtSignLogger('CommandLineUtils');

  /// Parses [arguments], a list of command-line arguments, matches them against the
  /// flags and options defined by this parser, and returns the result.
  ArgResults getParserResults(List<String> arguments) {
    var results;
    var parser = ArgParser();
    parser.addOption('redis_host',
        abbr: 'h',
        //defaultsTo: 'localhost',
        help: 'Host name or Ip address of the Redis server');
    parser.addOption('redis_port',
        abbr: 'p',
        //defaultsTo: '64',
        help: 'Port of the Redis server');
    parser.addOption('redis_auth',
        abbr: 'a', help: 'Authorization to access Redis server');
    try {
      if (arguments != null && arguments.isNotEmpty) {
        results = parser.parse(arguments);
        if (results.options.length != parser.options.length) {
          throw ArgParserException('Invalid Arguments \n' + parser.usage);
        }
      } else {
        throw ArgParserException('ArgParser Exception \n' + parser.usage);
      }
      return results;
    } on ArgParserException {
      throw ArgParserException('ArgParserException\n' + parser.usage);
    }
  }
}
