import 'dart:convert';
import 'dart:math';

import 'package:at_secondary/src/connection/outbound/outbound_client.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_message_listener.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

class MockOutboundClient extends Mock implements OutboundClient {}

class MockOutboundConnectionImpl extends Mock
    implements OutboundConnectionImpl {}

class MockAtConnectionMetaData extends Mock implements AtConnectionMetaData {}

/// The framing this package shipped before the rewrite, reproduced verbatim
/// from `origin/trunk`'s `OutboundMessageListener.messageHandler`.
///
/// This is what every atServer in the fleet that has not yet been upgraded is
/// running. During a rollout an upgraded server talks to un-upgraded ones and
/// the reverse, so the question that matters is not "is the new framing good"
/// but "does it read the wire the same way the old one did". Anywhere the two
/// disagree is a behaviour change that ships to the fleet, and each such case
/// has to be one we chose.
class TrunkFraming {
  final List<String> queue = [];
  final List<int> _buffer = [];

  void messageHandler(List<int> data) {
    if (data.isEmpty) {
      // trunk indexes data.last unguarded and throws StateError here; the
      // corpus never feeds an empty chunk, so this only keeps the reference
      // runnable.
      return;
    }
    if (data.length == 1 && data.first == 64) return;
    if (data.last == 64 && data.contains(10)) {
      _buffer.addAll(data.sublist(0, data.lastIndexOf(10) + 1));
    } else if (data.length > 1 && data.first == 64 && data.last == 64) {
      _buffer.addAll(data);
      _buffer.add(10);
    } else {
      _buffer.addAll(data);
    }
    if (_buffer.isNotEmpty && _buffer.last == 10) {
      queue.add(utf8.decode(_buffer).trim());
      _buffer.clear();
    }
  }
}

void main() {
  verbTestsSetUpLogging();

  OutboundClient mockClient = MockOutboundClient();
  OutboundSocketConnection mockConnection = MockOutboundConnectionImpl();
  AtConnectionMetaData mockMeta = MockAtConnectionMetaData();

  setUp(() {
    reset(mockClient);
    when(() => mockClient.toAtSign).thenReturn(alice);
    when(() => mockClient.toPort).thenReturn('25000');
    when(() => mockClient.toHost).thenReturn('localhost');
    when(() => mockClient.outboundConnection).thenReturn(mockConnection);
    when(() => mockConnection.metaData).thenReturn(mockMeta);
    when(() => mockMeta.isStale).thenReturn(false);
    when(() => mockMeta.isClosed).thenReturn(false);
  });

  /// Byte streams a peer atServer actually puts on an outbound connection.
  /// Every shape here is traceable to a writer in lib/src/verb/handler: the
  /// response handlers append `\n` then the prompt, which is `@` while the
  /// connection is unauthenticated and `@<atSign>@` once pol has run.
  final corpus = <String, String>{
    'lookup response, unauthenticated prompt': 'data:+1 555 0100\n@',
    'lookup response, pol-authenticated prompt': 'data:+1 555 0100\n$alice@',
    'all: response carrying JSON': 'data:{"key":"phone$alice","data":"+1"}\n$alice@',
    'a value containing an atSign': 'data:{"k":"mail@example.com"}\n$alice@',
    'a value that both starts and ends with an atSign':
        'data:{"k":"@bob and @carol@"}\n$alice@',
    'from: proof response': 'data:proof:sess$alice:challenge-text\n@',
    'error with a code': 'error:AT0015-key not found\n$alice@',
    'error as JSON': 'error:{"errorCode":"AT0015","errorDescription":"nope"}\n$alice@',
    'a null value': 'data:null\n$alice@',
    'an empty data payload': 'data:\n$alice@',
    'two responses back to back':
        'data:FIRST\n$alice@data:SECOND\n$alice@',
    'three responses back to back':
        'data:A\n$alice@data:B\n$alice@data:C\n$alice@',
    'a scan response listing keys':
        'data:["phone$alice","email$alice"]\n$alice@',
  };

  /// Runs one byte stream through both parsers under one segmentation and
  /// returns their queues.
  (List<String>, List<String>) both(String wire, List<int> splitPoints) {
    var bytes = utf8.encode(wire);
    var chunks = <List<int>>[];
    var start = 0;
    for (var p in splitPoints) {
      chunks.add(bytes.sublist(start, p));
      start = p;
    }
    chunks.add(bytes.sublist(start));
    chunks.removeWhere((c) => c.isEmpty);

    var trunk = TrunkFraming();
    var listener = OutboundMessageListener(mockClient);
    for (var chunk in chunks) {
      trunk.messageHandler(chunk);
      listener.messageHandler(chunk);
    }
    return (trunk.queue, listener.queuedForTest);
  }

  /// What each stream MUST frame to, written out by hand. These anchor the
  /// invariance checks below: without them, a parser that framed nothing at
  /// all would be perfectly segmentation-invariant.
  final expected = <String, List<String>>{
    'lookup response, unauthenticated prompt': ['data:+1 555 0100'],
    'lookup response, pol-authenticated prompt': ['data:+1 555 0100'],
    'all: response carrying JSON': ['data:{"key":"phone$alice","data":"+1"}'],
    'a value containing an atSign': ['data:{"k":"mail@example.com"}'],
    'a value that both starts and ends with an atSign':
        ['data:{"k":"@bob and @carol@"}'],
    'from: proof response': ['data:proof:sess$alice:challenge-text'],
    'error with a code': ['error:AT0015-key not found'],
    'error as JSON':
        ['error:{"errorCode":"AT0015","errorDescription":"nope"}'],
    'a null value': ['data:null'],
    'an empty data payload': ['data:'],
    'two responses back to back': ['data:FIRST', 'data:SECOND'],
    'three responses back to back': ['data:A', 'data:B', 'data:C'],
    'a scan response listing keys': ['data:["phone$alice","email$alice"]'],
  };

  group('framing is invariant under however the network splits the bytes', () {
    test('every response shape frames to what it should, delivered whole', () {
      for (var entry in corpus.entries) {
        var (_, newOut) = both(entry.value, []);
        expect(newOut, expected[entry.key],
            reason: 'baseline wrong for "${entry.key}" -- every invariance'
                ' check below is measured against this, so it has to be right'
                ' first');
      }
    });

    test('and to the same thing at every single split point', () {
      var broken = <String>[];
      for (var entry in corpus.entries) {
        var length = utf8.encode(entry.value).length;
        for (var split = 1; split < length; split++) {
          var (_, newOut) = both(entry.value, [split]);
          if (newOut.toString() != expected[entry.key].toString()) {
            broken.add('${entry.key} @split=$split of $length -> $newOut');
          }
        }
      }
      expect(broken, isEmpty,
          reason: 'a peer that answers correctly must be read correctly'
              ' regardless of where TCP happens to cut:\n'
              '${broken.take(12).join('\n')}');
    });

    test('and at every pair of split points', () {
      var broken = <String>[];
      for (var entry in corpus.entries) {
        var length = utf8.encode(entry.value).length;
        for (var a = 1; a < length; a++) {
          for (var b = a + 1; b < length; b++) {
            var (_, newOut) = both(entry.value, [a, b]);
            if (newOut.toString() != expected[entry.key].toString()) {
              broken.add('${entry.key} @splits=$a,$b -> $newOut');
            }
          }
        }
      }
      expect(broken, isEmpty,
          reason: 'two-way splits:\n${broken.take(12).join('\n')}');
    });

    test('and when delivered one byte at a time', () {
      for (var entry in corpus.entries) {
        var length = utf8.encode(entry.value).length;
        var (_, newOut) =
            both(entry.value, List.generate(length - 1, (i) => i + 1));
        expect(newOut, expected[entry.key],
            reason: 'byte-at-a-time delivery of "${entry.key}"');
      }
    });

    test('and under randomised segmentation', () {
      var random = Random(20260826); // fixed seed, so a failure reproduces
      var broken = <String>[];
      for (var entry in corpus.entries) {
        var length = utf8.encode(entry.value).length;
        for (var trial = 0; trial < 300; trial++) {
          var points = <int>{};
          for (var i = 0; i < random.nextInt(6); i++) {
            points.add(1 + random.nextInt(length - 1));
          }
          var sorted = points.toList()..sort();
          var (_, newOut) = both(entry.value, sorted);
          if (newOut.toString() != expected[entry.key].toString()) {
            broken.add('${entry.key} @$sorted -> $newOut');
          }
        }
      }
      expect(broken, isEmpty,
          reason: 'randomised segmentation:\n${broken.take(12).join('\n')}');
    });
  });

  group('what an un-upgraded peer reader would have done with the same bytes',
      () {
    test('is wrong often enough to be worth the change, and never in a way'
        ' the new framing loses', () {
      var trunkWrong = 0;
      var total = 0;
      var newWrong = <String>[];
      for (var entry in corpus.entries) {
        var length = utf8.encode(entry.value).length;
        for (var split = 1; split < length; split++) {
          var (trunkOut, newOut) = both(entry.value, [split]);
          total++;
          if (trunkOut.toString() != expected[entry.key].toString()) {
            trunkWrong++;
          }
          if (newOut.toString() != expected[entry.key].toString()) {
            newWrong.add('${entry.key} @$split');
          }
        }
      }
      expect(newWrong, isEmpty);
      // Informational, and the reason this change exists: the shipped framing
      // mis-reads a correct peer at a large fraction of split points.
      expect(trunkWrong, greaterThan(0),
          reason: 'if the shipped framing never disagreed there would be'
              ' nothing here worth changing -- $trunkWrong of $total');
      // ignore: avoid_print
      print('shipped framing mis-framed $trunkWrong of $total single-split '
          'deliveries; new framing mis-framed ${newWrong.length}');
    });
  });
}
