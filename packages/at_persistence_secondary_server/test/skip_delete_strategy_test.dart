import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/sync/skip_deletes_strategy.dart';
import 'package:test/test.dart';

void main() async {
  group('A group of tests to verify skip deletes strategy', () {
    test(
        'Test to verify shouldInclude returns true when last commit entry is delete',
        () {
      int skipDeletesUntil = 15;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone@alice', CommitOp.DELETE, DateTime.now())
            ..commitId = 15;
      bool shouldInclude =
          skipStrategy.shouldIncludeEntryInSyncResponse(commitEntry, 5, '.*');
      expect(shouldInclude, true);
    });
    test(
        'Test to verify shouldInclude returns false when commitOp is DELETE and commit entry commitId is in between passed commitId and skipDeletesUntil value',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone@alice', CommitOp.DELETE, DateTime.now())
            ..commitId = 5;
      bool shouldInclude =
          skipStrategy.shouldIncludeEntryInSyncResponse(commitEntry, -1, '.*');
      expect(shouldInclude, false);
    });
    test(
        'Test to verify shouldInclude returns true when commitOp is UPDATE and commit entry commitId is in between passed commitId and skipDeletesUntil value',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 5;
      bool shouldInclude =
          skipStrategy.shouldIncludeEntryInSyncResponse(commitEntry, -1, '.*');
      expect(shouldInclude, true);
    });
    test(
        'Test to verify shouldInclude returns false when commitOp is UPDATE and key regex does not match passed regex',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 5;
      bool shouldInclude = skipStrategy.shouldIncludeEntryInSyncResponse(
          commitEntry, -1, '.wavi');
      expect(shouldInclude, false);
    });
    test(
        'Test to verify shouldInclude returns true when commitOp is UPDATE and key regex matches passed regex',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 5;
      bool shouldInclude = skipStrategy.shouldIncludeEntryInSyncResponse(
          commitEntry, -1, '.buzz');
      expect(shouldInclude, true);
    });
    test(
        'Test to verify shouldInclude returns true when commitOp is DELETE and commit entry commitId is greater than skipDeletesUntil values',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone.buzz@alice', CommitOp.DELETE, DateTime.now())
            ..commitId = 25;
      bool shouldInclude = skipStrategy.shouldIncludeEntryInSyncResponse(
          commitEntry, -1, '.buzz');
      expect(shouldInclude, true);
    });
    test(
        'Test to verify shouldInclude returns true when commitOp is UPDATE and key regex matches passed regex, key namespace is in enrolled namespace',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 5;
      var enrolledNamespaces = ['buzz', 'contacts'];
      bool shouldInclude = skipStrategy.shouldIncludeEntryInSyncResponse(
          commitEntry, -1, '.buzz',
          enrolledNamespace: enrolledNamespaces);
      expect(shouldInclude, true);
    });
    test(
        'Test to verify shouldInclude returns false when commitOp is UPDATE and key regex matches passed regex, key namespace is NOT in enrolled namespace',
        () {
      int skipDeletesUntil = 10;
      int latestCommitId = 15;
      var skipStrategy = SkipDeleteStrategy(skipDeletesUntil, latestCommitId);
      final commitEntry =
          CommitEntry('phone.buzz@alice', CommitOp.UPDATE, DateTime.now())
            ..commitId = 5;
      var enrolledNamespaces = ['wavi', 'contacts'];
      bool shouldInclude = skipStrategy.shouldIncludeEntryInSyncResponse(
          commitEntry, -1, '.buzz',
          enrolledNamespace: enrolledNamespaces);
      expect(shouldInclude, false);
    });
  });
}
