import 'package:at_server_spec/grammar.dart';
import 'package:test/test.dart';

void main() {
  const lexer = AtProtocolLexer();

  test('parseAs returns the compat map for a known verb', () {
    final m = lexer.parseAs('from', 'from:@alice');
    expect(m, isNotNull);
    expect(m!['atSign'], '@alice');
    expect(m['clientConfig'], isNull);
  });

  test('parseAs returns null when the command does not match', () {
    expect(lexer.parseAs('from', 'from:'), isNull);
  });

  test('supports() reflects ported verbs and the deferred stream verb', () {
    expect(lexer.supports('update'), isTrue);
    expect(lexer.supports('notify:all'), isTrue);
    // stream is intentionally not ported yet -> server falls back to regex.
    expect(lexer.supports('stream'), isFalse);
    expect(lexer.parseAs('stream', 'stream:init@bob namespace:wavi'), isNull);
  });

  test('parseAs is null for an unregistered verb name', () {
    expect(lexer.parseAs('bogusverb', 'bogusverb:x'), isNull);
  });

  test('grammarForVerb exposes the grammar and its field names', () {
    final g = lexer.grammarForVerb('update');
    expect(g, isNotNull);
    expect(g!.fieldNames, contains('value'));
    expect(g.fieldNames, contains('atKey'));
  });

  test('registry covers the whole protocol except stream', () {
    // A representative sanity check that the long tail is registered.
    for (final v in [
      'from', 'pkam', 'cram', 'pol', 'noop', 'info',
      'llookup', 'lookup', 'plookup', 'scan',
      'update', 'update:meta', 'delete',
      'notify', 'notify:list', 'notify:all', 'notify:status',
      'notify:fetch', 'notify:remove',
      'monitor', 'stats', 'sync', 'sync:from',
      'enroll', 'otp', 'keys', 'config', 'batch',
    ]) {
      expect(verbGrammars.containsKey(v), isTrue, reason: 'missing grammar: $v');
    }
  });
}
