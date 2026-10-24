import 'dart:async';

import 'package:at_secondary/src/connection/inbound/inbound_write_queue.dart';
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
}
