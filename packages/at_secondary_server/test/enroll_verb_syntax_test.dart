import 'package:at_server_spec/verbs.dart';
import 'package:test/test.dart';

/// The enroll operation alternation the server parses comes from at_commons.
/// `enroll:infons:<namespace>` is its newest member, and these pins are what
/// goes red if the at_commons floor slips below the release that lists it.
void main() {
  final RegExp enroll = RegExp(Enroll().syntax(), caseSensitive: false);

  RegExpMatch? match(String command) => enroll.firstMatch(command);

  group('enroll operation syntax', () {
    test('infons parses, and carries the namespace', () {
      final m = match('enroll:infons:wavi');
      expect(m, isNotNull,
          reason: 'if this fails the verb does not exist as far as the '
              'command parser is concerned, which reads exactly like the '
              'handler being missing');
      expect(m!.namedGroup('operation'), 'infons');
      expect(m.namedGroup('listNamespace'), 'wavi',
          reason: 'infons shares the listNamespace capture group with listns');
    });

    test('an unknown operation is refused', () {
      expect(match('enroll:bogusop:wavi'), isNull);
      expect(match('enroll:'), isNull);
    });

    test('infons is exactly as strict as the operations around it', () {
      // A trailing suffix is absorbed into enrollParams for EVERY operation,
      // so `enroll:listnsX:w` parses as listns with params `X:w`. The pin is
      // that infons behaves like its neighbours rather than specially.
      for (final pair in [
        ['infons', 'listns'],
        ['infons', 'list']
      ]) {
        final mine = match('enroll:${pair[0]}X:wavi');
        final theirs = match('enroll:${pair[1]}X:wavi');
        expect(mine != null, theirs != null,
            reason: '${pair[0]} must be no more and no less permissive than '
                '${pair[1]}');
        expect(mine?.namedGroup('operation'), pair[0]);
      }
    });

    test('every operation at_commons defines parses', () {
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
        'enroll:infons:wavi',
      ]) {
        expect(match(command), isNotNull, reason: command);
      }
    });

    test('listns is not shadowed by list', () {
      // Alternation order decides this, and `list` is a prefix of `listns`.
      expect(match('enroll:listns:wavi')!.namedGroup('operation'), 'listns');
    });
  });
}
