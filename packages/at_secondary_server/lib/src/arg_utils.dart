import 'package:args/args.dart';
import 'package:at_utils/at_logger.dart';

/// A class for taking a list of raw command line arguments and parsing out
/// options and flags from them.
class CommandLineParser {
  var logger = AtSignLogger('CommandLineUtils');

  /// Parses [arguments], a list of command-line arguments, matches them against the
  /// flags and options defined by this parser, and returns the result.
  ArgResults getParserResults(List<String>? arguments) {
    ArgResults results;
    var parser = ArgParser();
    parser.addOption('at_sign', abbr: 'a', help: 'AtSign handle');
    parser.addOption('server_port',
        abbr: 'p', help: 'Port of the secondary server');
    parser.addOption('shared_secret',
        abbr: 's', help: 'Shared secret of the AtSign');
    parser.addFlag('training',
        abbr: 't',
        defaultsTo: false,
        negatable: false,
        help:
            'Training mode - will exit immediately after fully starting the server');

    try {
      if (arguments != null && arguments.isNotEmpty) {
        results = parser.parse(arguments);
        if (results.options.length != parser.options.length) {
          throw ArgParserException(
              'Invalid Arguments. Usage: \n${parser.usage}');
        }
      } else {
        throw ArgParserException('Invalid Arguments. Usage: \n${parser.usage}');
      }
      return results;
    } on ArgParserException {
      throw ArgParserException('Invalid Arguments. Usage: \n${parser.usage}');
    }
  }
}
