import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:at_commons/at_commons.dart';
import 'package:at_utils/at_logger.dart';
import 'package:meta/meta.dart';

enum AtServerTelemetryEventType {
  connect,
  disconnect,
  request,
  response,
  errorResponse,
  stream
}

class AtServerTelemetryEvent extends AtTelemetryEvent {
  AtServerTelemetryEventType eventType;

  AtServerTelemetryEvent(
      {required this.eventType, dynamic value, DateTime? time})
      : super(eventType.name, value, time: time);

  Map<String, dynamic> toJson() => {
    'eventType': eventType.name,
    'time': time.millisecondsSinceEpoch,
    'value':value
  };
}

class AtServerInteractionEvent extends AtServerTelemetryEvent {
  String from;
  String to;

  AtServerInteractionEvent(
      {required AtServerTelemetryEventType eventType,
      required this.from,
      required this.to,
      dynamic value,
      DateTime? time})
      : super(eventType: eventType, value: value, time: time);

  @override
  Map<String, dynamic> toJson() => {
    'eventType': eventType.name,
    'time': time.millisecondsSinceEpoch,
    'from':from,
    'to':to,
    'value':value
  };
}

class AtServerTelemetrySample extends AtTelemetrySample {
  AtServerTelemetrySample(super.name, super.value);
}

@experimental
class AtServerTelemetryService extends AtTelemetryService {
  AtSignLogger logger = AtSignLogger('AtServerTelemetryService');

  AtServerTelemetryService(
      {StreamController<AtServerTelemetryEvent>? controller})
      : super(controller: controller);

  final List<AtTelemetrySample> _samples = <AtTelemetrySample>[];

  publish(AtServerTelemetryEvent event) {
    try {
      controller.sink.add(event);
    } catch (e) {
      logger.warning(e);
    }
  }

  interaction(
      {required AtServerTelemetryEventType eventType,
      required String from,
      required String to,
      dynamic value,
      DateTime? time}) {
    publish(AtServerInteractionEvent(
        eventType: eventType, from: from, to: to, value: value, time: time));
  }

  @override
  Iterator<AtTelemetrySample> get samples => _samples.iterator;

  @override
  Future<void> takeSample({String? sampleName}) async {
    // TODO
  }

  @override
  void addSample(AtTelemetrySample sample) {
    // TODO
  }
}

@experimental
class WebHookAtTelemetryConsumer {
  AtSignLogger logger = AtSignLogger('WebHookAtTelemetryConsumer');
  final AtTelemetryService telemetry;
  final Uri uri;

  final int queueSize;
  final HttpClient httpClient = HttpClient();
  final Queue<AtServerTelemetryEvent> queue = Queue();
  late final StreamSubscription telemetrySubscription;

  WebHookAtTelemetryConsumer(this.telemetry, this.uri,
      {this.queueSize = 1000}) {
    telemetrySubscription = telemetry.stream.listen(eventHandler);
  }

  void close() {
    telemetrySubscription.cancel();
    httpClient.close();
  }

  void eventHandler(AtTelemetryEvent event) async {
    if (event is! AtServerTelemetryEvent) {
      return;
    }
    if ((queue.length + 1) > queueSize) {
      queue.removeFirst();
    }
    queue.addLast(event);

    unawaited(send());
  }

  bool processingQueue = false;

  Future<void> send() async {
    if (processingQueue) {
      return;
    }
    processingQueue = true;
    try {
      while (queue.isNotEmpty) {
        AtTelemetryEvent event = queue.removeFirst();

        if (backedOff()) {
          // While we're in a backed-off state, we discard all events
          continue;
        }

        try {
          final request = await httpClient.postUrl(uri);
          request.headers.set(
              HttpHeaders.contentTypeHeader, "application/json; charset=UTF-8");
          request.write(jsonEncode(event));

          final HttpClientResponse response = await request.close();
          if (response.statusCode == 200) {
            clearBackOff();
          } else {
            response.transform(utf8.decoder).listen((contents) {
              logger.warning(contents);
            });
            backOff(5);
          }
        } catch (e) {
          logger.warning('$e');
          backOff(5);
        }
      }
    } catch (e, st) {
      logger.warning('$e');
      logger.warning('$st');
    } finally {
      processingQueue = false;
    }

    if (queue.isNotEmpty) {
      unawaited(send());
    }
  }

  int backOffUntil = 0;

  clearBackOff() {
    backOffUntil = 0;
  }

  backOff(int backOffDuration) {
    logger.warning('Backing off for $backOffDuration seconds');
    backOffUntil = DateTime.now()
        .add(Duration(seconds: backOffDuration))
        .millisecondsSinceEpoch;
  }

  bool backedOff() {
    return DateTime.now().millisecondsSinceEpoch < backOffUntil;
  }
}
