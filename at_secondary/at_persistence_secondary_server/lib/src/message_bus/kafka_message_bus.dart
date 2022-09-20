import 'dart:convert';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/message_bus/secondary_message_bus.dart';
import 'package:at_utils/at_logger.dart';
import 'package:http/http.dart' as http;

class KafkaMessageBus extends SecondaryMessageBus {
  static final KafkaMessageBus _singleton = KafkaMessageBus._internal();

  KafkaMessageBus._internal();

  factory KafkaMessageBus.getInstance() {
    return _singleton;
  }

  var logger = AtSignLogger('KafkaMessageBus');

  @override
  publish(String key, AtData atData, String owner, {String? sharedWith}) async {
    var client = http.Client();
    try {
      var url = Uri.parse('http://localhost:8082/topics/atsign_topic');
      var response = await client.post(url,
          headers: {
            'Content-Type': 'application/vnd.kafka.json.v2+json',
            'Accept': 'application/vnd.kafka.v2+json'
          },
          body: jsonEncode({
            "records": [
              {
                "value": {
                  "atKey": key,
                  "value": atData.data,
                  "metadata": atData.metaData,
                  "owner": owner,
                  "sharedWith": sharedWith
                }
              }
            ]
          }));
      var decodedResponse = jsonDecode(utf8.decode(response.bodyBytes)) as Map;
      logger.info(
          '$key published to kafka message bus with statusCode: ${response.statusCode} - $decodedResponse');
    } finally {
      client.close();
    }
  }
}
