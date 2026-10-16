import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads [socket] one answer at a time: each `data:` or `error:` line, and
/// each prompt that names an atSign, such as `@alice@`; a bare `@` prompt is
/// skipped. The reader answers null once the atServer has closed the
/// connection, and throws if nothing arrives within 30 seconds.
Future<String?> Function() answersOf(Socket socket) {
  final StreamController<String> lines = StreamController<String>();
  String pending = '';
  socket.listen((data) {
    pending += utf8.decode(data);
    int end;
    while ((end = pending.indexOf('\n')) != -1) {
      lines.add(pending.substring(0, end).trim());
      pending = pending.substring(end + 1);
    }
    // NOTE a prompt ends an answer without a newline.
    if (RegExp(r'^@?[^\s:@]*@$').hasMatch(pending.trim())) {
      if (pending.trim() != '@') {
        lines.add(pending.trim());
      }
      pending = '';
    }
  }, onDone: lines.close, onError: (_) => lines.close());
  final StreamIterator<String> answers = StreamIterator(lines.stream);
  return () async {
    if (!await answers.moveNext().timeout(const Duration(seconds: 30))) {
      return null;
    }
    final String line = answers.current;
    return RegExp(r'^@(data|error):').hasMatch(line) ? line.substring(1) : line;
  };
}

/// Whether [answer] is a prompt naming an atSign, such as `@alice@`.
bool isPrompt(String? answer) =>
    answer != null && RegExp(r'^@[^\s:@]*@$').hasMatch(answer);
