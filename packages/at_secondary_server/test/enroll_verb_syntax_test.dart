import 'package:at_commons/at_commons.dart';
import 'package:at_server_spec/verbs.dart';
import 'package:test/test.dart';

/// This server accepts one enroll operation that at_commons does not describe.
///
/// `enroll:infons:<namespace>` answers facts about a namespace. at_commons
/// owns the enroll operation alternation and does not list `infons`, so
/// [Enroll] inserts it locally. That is a real divergence between what this
/// server accepts and what at_commons documents, and it is meant to be short
/// lived — these tests are what makes it visible rather than forgotten.
void main() {
  final RegExp enroll = RegExp(Enroll().syntax(), caseSensitive: false);

  RegExpMatch? match(String command) => enroll.firstMatch(command);

  group('the locally-added enroll:infons operation', () {
    test('parses, and carries the namespace', () {
      final m = match('enroll:infons:wavi');
      expect(m, isNotNull,
          reason: 'if this fails the verb does not exist as far as the '
              'command parser is concerned, which reads exactly like the '
              'handler being missing');
      expect(m!.namedGroup('operation'), 'infons');
      expect(m.namedGroup('listNamespace'), 'wavi',
          reason: 'infons reuses at_commons\' existing listNamespace capture '
              'group, so nothing else in the pattern had to move');
    });

    test('an unknown operation is still refused', () {
      // The negative control, and the one assertion most worth keeping when
      // somebody deletes the override: it is what proves the insertion widened
      // the alternation by exactly one token rather than loosening it into
      // accepting anything.
      expect(match('enroll:bogusop:wavi'), isNull);
      expect(match('enroll:'), isNull);
    });

    test('infons is exactly as strict as the operations around it', () {
      // Measured, because the first version of this test asserted a
      // strictness at_commons\' pattern has never had: a trailing suffix is
      // absorbed into enrollParams for EVERY operation, so `enroll:listnsX:w`
      // parses as listns with params `X:w`. That is upstream behaviour and
      // not something the insertion should change either way. What matters is
      // that infons behaves like its neighbours rather than specially.
      for (final pair in [['infons', 'listns'], ['infons', 'list']]) {
        final mine = match('enroll:${pair[0]}X:wavi');
        final theirs = match('enroll:${pair[1]}X:wavi');
        expect(mine != null, theirs != null,
            reason: '${pair[0]} must be no more and no less permissive than '
                '${pair[1]}');
        expect(mine?.namedGroup('operation'), pair[0]);
      }
    });

    test('every operation at_commons defines still parses', () {
      // The override INSERTS into at_commons\' pattern rather than replacing
      // it, so an upstream change still reaches this server. These are the
      // shapes that would break if it ever became a stale copy.
      for (final command in [
        'enroll:request:{"appName":"a"}',
        'enroll:approve:{"enrollmentId":"x"}',
        'enroll:deny:{"enrollmentId":"x"}',
        'enroll:revoke:{"enrollmentId":"x"}',
        'enroll:revoke:force:{"enrollmentId":"x"}',
        'enroll:unrevoke:{"enrollmentId":"x"}',
        'enroll:delete:{"enrollmentId":"x"}',
        'enroll:update:{"enrollmentId":"x"}',
        'enroll:fetch:{"enrollmentId":"x"}',
        'enroll:list',
        'enroll:listns:wavi',
      ]) {
        expect(match(command), isNotNull, reason: command);
      }
    });

    test('listns is not shadowed by list', () {
      // Alternation order decides this, and `list` is a prefix of `listns`.
      // Inserting `infons` must not have disturbed it.
      expect(match('enroll:listns:wavi')!.namedGroup('operation'), 'listns');
    });

    test('DELETE THE OVERRIDE when this fails: at_commons has caught up', () {
      // A tripwire, not a preference. When a published at_commons lists
      // `infons` itself, the local insertion in at_server_spec's Enroll verb
      // becomes a stale fork of a pattern this package should be taking
      // unchanged — and nothing else would ever tell us.
      //
      // To clear it: delete `_buildSyntax`/`_syntaxWithInfons` from
      // at_server_spec's Enroll, return VerbSyntax.enroll again, raise the
      // at_commons floor in the same commit, and delete this test.
      expect(VerbSyntax.enroll.contains('infons'), isFalse,
          reason: 'at_commons now defines the infons operation, so this '
              'server no longer needs to add it locally');
    });
  });
}
