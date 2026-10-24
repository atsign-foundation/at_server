import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:at_commons/at_commons.dart' show ConnectionInvalidException;
import 'package:at_secondary/src/connection/inbound/dummy_inbound_connection.dart';
import 'package:at_secondary/src/connection/inbound/inbound_write_queue.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('Given a transport that stops taking writes after each one', () {
    late InboundWriteQueue<String> queue;
    late StreamSubscription<String> transport;
    late List<String> taken;

    setUp(() {
      queue = InboundWriteQueue<String>(maxUnsentBytes: 1000);
      taken = <String>[];
      transport = queue.stream.listen(null);
      transport.onData((String data) {
        taken.add(data);
        transport.pause();
      });
    });

    tearDown(() => transport.cancel());

    test(
        'when it resumes, then the queue still counts the writes it has not taken',
        () async {
      queue.add('a' * 10, 10);
      queue.add('b' * 20, 20);
      queue.add('c' * 40, 40);
      expect(taken, ['a' * 10]);
      expect(queue.unsentBytes, 60);

      transport.resume();
      await Future<void>.delayed(Duration.zero);

      expect(taken, ['a' * 10, 'b' * 20]);
      expect(queue.unsentBytes, 40);
    });

    test('when it resumes, then drained waits for the writes it has not taken',
        () async {
      queue.add('a' * 10, 10);
      queue.add('b' * 20, 20);
      queue.add('c' * 40, 40);
      bool drained = false;
      unawaited(queue.drained.then((_) => drained = true));

      transport.resume();
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);

      transport.resume();
      await Future<void>.delayed(Duration.zero);
      expect(taken, ['a' * 10, 'b' * 20, 'c' * 40]);
      expect(drained, isTrue);
    });
  });

  group('Given a string', () {
    test('when it is measured, then the count is its UTF-8 length', () {
      final Random random = Random(2874);
      final List<String> strings = [
        '\u007f',
        '\u0080',
        '\u07ff',
        '\u0800',
        '\ud7ff',
        '\ud800\udc00',
        '\udbff\udfff',
        '\udbff',
        '\udc00',
        '\ue000',
        '\uffff',
        '',
        'notification: {"id":"n1"}\n',
        'é',
        '€',
        '😀',
        '\uD83D',
        '\uDE00',
        'a\uD83D',
        '\uDE00\uD83D',
        'mixed é€😀 text',
        for (int i = 0; i < 1000; i++)
          String.fromCharCodes(
              [for (int j = 0; j < 20; j++) random.nextInt(0x10000)]),
      ];
      for (final String text in strings) {
        expect(utf8Length(text), utf8.encode(text).length,
            reason: 'for ${text.codeUnits}');
      }
    });
  });

  group('Given a queue whose transport has stopped taking writes', () {
    late InboundWriteQueue<String> queue;
    late StreamSubscription<String> transport;
    late List<String> taken;

    setUp(() {
      queue = InboundWriteQueue<String>(maxUnsentBytes: 100);
      taken = <String>[];
      transport = queue.stream.listen(taken.add)..pause();
    });

    tearDown(() => transport.cancel());

    test(
        'when a write takes the waiting bytes exactly to the limit, then it is taken',
        () {
      expect(queue.add('a' * 60, 60), isTrue);
      expect(queue.add('b' * 40, 40), isTrue);
      expect(queue.unsentBytes, 100);
      expect(queue.add('c', 1), isFalse);
    });

    test('when the queue closes, then a wait for it to drain is released',
        () async {
      queue.add('a' * 10, 10);
      bool drained = false;
      unawaited(queue.drained.then((_) => drained = true));
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse, reason: 'precondition: still waiting');

      queue.close();
      await Future<void>.delayed(Duration.zero);

      expect(drained, isTrue);
    });

    test('when it closes and the transport resumes, then nothing more is sent',
        () async {
      queue.add('a' * 10, 10);
      queue.close();

      transport.resume();
      await Future<void>.delayed(Duration.zero);

      expect(taken, isEmpty);
      expect(queue.unsentBytes, 0);
    });

    test('when it has closed, then a wait for it to drain ends at once',
        () async {
      queue.add('a' * 10, 10);
      queue.close();
      bool drained = false;

      unawaited(queue.drained.then((_) => drained = true));
      await Future<void>.delayed(Duration.zero);

      expect(drained, isTrue);
    });

    test('when it has closed, then add takes nothing', () {
      queue.close();

      expect(queue.add('a', 1), isFalse);
      expect(queue.unsentBytes, 0);
    });

    test(
        'when it has closed, then write is refused as invalid without the over-limit warning',
        () async {
      final AtSignLogger logger = AtSignLogger('queue test');
      final Level prior = logger.logger.level;
      logger.level = 'warning';
      final List<String> warnings = <String>[];
      final StreamSubscription<LogRecord> logs = logger.logger.onRecord
          .where((LogRecord r) => r.level == Level.WARNING)
          .listen((LogRecord r) => warnings.add(r.message));
      addTearDown(() async {
        await logs.cancel();
        logger.logger.level = prior;
      });
      queue.close();

      await expectLater(
          queue.write('a', 1,
              connection: DummyInboundConnection(),
              logger: logger,
              closeAtLimit: () async {}),
          throwsA(isA<ConnectionInvalidException>()));
      expect(warnings, isEmpty);
    });
  });

  group('Given a queue with no transport bound yet', () {
    test('when written to, then it counts the write until a transport takes it',
        () async {
      final InboundWriteQueue<String> queue =
          InboundWriteQueue<String>(maxUnsentBytes: 100);
      queue.add('a' * 10, 10);
      expect(queue.unsentBytes, 10);

      final List<String> taken = <String>[];
      final StreamSubscription<String> transport =
          queue.stream.listen(taken.add);
      addTearDown(transport.cancel);
      await Future<void>.delayed(Duration.zero);

      expect(taken, ['a' * 10]);
      expect(queue.unsentBytes, 0);
    });
  });

  group('Given a bound transport that fails', () {
    test(
        'when a wait for the queue to drain is pending, then it is released and the failure reported',
        () async {
      final InboundWriteQueue<String> queue =
          InboundWriteQueue<String>(maxUnsentBytes: 100);
      final Completer<void> transport = Completer<void>();
      late StreamSubscription<String> subscription;
      Object? failure;
      queue.bindOnce((Stream<String> stream) {
        subscription = stream.listen((_) {})..pause();
        return transport.future;
      }, onFailed: (Object e) => failure = e, onEnded: () {});
      addTearDown(() => subscription.cancel());
      await Future<void>.delayed(Duration.zero);
      queue.add('a' * 10, 10);
      bool drained = false;
      unawaited(queue.drained.then((_) => drained = true));

      transport.completeError(StateError('transport reset'));
      await Future<void>.delayed(Duration.zero);

      expect(failure, isA<StateError>());
      expect(drained, isTrue);
    });
  });
}
