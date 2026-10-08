import 'dart:async';
import 'dart:io';

import 'package:at_secondary/src/server/at_certificate_validation.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/bootstrapper.dart';
import 'package:test/test.dart';

import 'test_utils.dart';

/// A job whose check and restart are stand-ins, so no server is touched.
class _Job extends AtCertificateValidationJob {
  _Job({this.checkError, this.restartNeeded = false, this.restartError})
      : super(AtSecondaryServerImpl.getInstance(), 'unused', false);

  final Object? checkError;
  final bool restartNeeded;
  final Object? restartError;

  @override
  Future<bool> isRestartRequired() async {
    if (checkError != null) throw checkError!;
    return restartNeeded;
  }

  @override
  Future<bool> waitUntilReadyToRestart() async => true;

  @override
  Future<void> restartServer() async {
    if (restartError != null) throw restartError!;
  }
}

void main() {
  verbTestsSetUpLogging();

  /// Runs [job]'s check in a zone and returns every error handed to it.
  Future<List<Object>> handedToZone(_Job job) async {
    final List<Object> handed = [];
    final Completer<void> done = Completer();
    unawaited(runZonedGuarded(() async {
      try {
        await job.checkAndRestartIfRequired();
      } finally {
        done.complete();
      }
    }, (e, _) => handed.add(e)));
    await done.future;
    await Future.delayed(Duration.zero);
    return handed;
  }

  test('a failed check is logged, and the server keeps running', () async {
    expect(
        await handedToZone(_Job(checkError: StateError('injected'))), isEmpty);
  });

  test('a failed restart is logged and handed to the zone the server runs in',
      () async {
    final handed = await handedToZone(
        _Job(restartNeeded: true, restartError: StateError('injected')));
    expect(handed, [isA<StateError>()],
        reason: 'a paused or stopped server cannot serve, so its zone must '
            'see the failure and stop it');
  });

  test('a failed restart stops the server even when it is a SocketException',
      () async {
    final handed = await handedToZone(_Job(
        restartNeeded: true,
        restartError: const SocketException('bind failed')));
    expect(handed, hasLength(1));
    expect(SecondaryServerBootStrapper.stopsServer(handed.single), isTrue,
        reason: 'the zone spares a SocketException, which would leave a '
            'stopped server running');
  });

  test('control: the zone spares a SocketException on its own', () {
    expect(
        SecondaryServerBootStrapper.stopsServer(
            const SocketException('one client')),
        isFalse);
  });

  test('control: no restart needed, nothing handed on', () async {
    expect(await handedToZone(_Job()), isEmpty);
  });
}
