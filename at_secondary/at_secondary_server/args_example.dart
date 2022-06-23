import 'package:args/args.dart';

void main(List<String> arguments) {

  final parser = ArgParser()..addOption('example', abbr: 'e');

  ArgResults argResults = parser.parse(arguments);
  
  print(argResults['example']);
  
}