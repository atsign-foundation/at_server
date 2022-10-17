import 'package:at_commons/at_commons.dart';
import 'package:at_end2end_test/conf/config_util.dart';
import 'pkam_utils.dart';

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

const int maxRetryCount = 10;

/// Contains all [_AtSignConfig] instances we know about so we can avoid loads of boilerplate elsewhere
LinkedHashMap<String, _AtSignConfig> atSignConfigMap = LinkedHashMap();

/// Return a List of atSigns known to these e2e test utils. Ordering is the order of insertion in [_loadYaml] which is
/// currently [@cicd1, @cicd2]
List<String> knownAtSigns() {
  _loadTheYaml();
  return List.from(atSignConfigMap.keys);
}

/// Utility method which will return a socket handler. Gets config from [atSignConfigMap] which in turn calls
/// [_loadTheYaml] if it hasn't yet been loaded.
/// Can evolve this to use a pooling approach if/when it becomes necessary.
Future<SimpleOutboundSocketHandler> getSocketHandler(atSign) async {
  _loadTheYaml();

  _AtSignConfig? asc = atSignConfigMap[atSign];
  if (asc == null) {
    throw _NoSuchAtSignException('$atSign not configured');
  }
  var handler = SimpleOutboundSocketHandler._(asc.host, asc.port, atSign);
  await handler.connect();
  handler.startListening();
  await handler.sendFromAndPkam();

  return handler;
}

/// A simple wrapper around a socket for @ protocol communication.
class SimpleOutboundSocketHandler {
  late Queue _queue;
  final _buffer = ByteBuffer(capacity: 10240000);

  // ignore: prefer_typing_uninitialized_variables
  String host;
  int port;
  String atSign;
  SecureSocket? socket;

  /// Try to open a socket
  SimpleOutboundSocketHandler._(this.host, this.port, this.atSign) {
    _queue = Queue();
  }

  void close() {
    print("Closing SimpleOutboundSocketHandler for $atSign ($host:$port)");
    socket!.destroy();
  }

  Future<void> connect() async {
    int retryCount = 1;
    while (retryCount < maxRetryCount) {
      try {
        socket = await SecureSocket.connect(host, port);
        if (socket != null) {
          return;
        }
      } on Exception {
        print('retrying "$host:$port" for connection.. $retryCount');
        await Future.delayed(Duration(seconds: 1));
        retryCount++;
      }
    }
    throw Exception("Failed to connect to $host:$port after $retryCount attempts");
  }

  void startListening() {
    socket!.listen(_messageHandler);
  }

  /// Socket write
  Future<void> writeCommand(String command, {bool log = true}) async {
    if (log) {
      print('command sent: $command');
    }
    if (! command.endsWith('\n')) {
      command = command + '\n';
    }
    socket!.write(command);
  }

  /// Runs a from verb and pkam verb on the atsign param.
  Future<void> sendFromAndPkam() async {
    // FROM VERB
    await writeCommand('from:$atSign');
    var response = await read(timeoutMillis:4000);
    response = response.replaceAll('data:', '');
    var pkamDigest = generatePKAMDigest(atSign, response);

    // PKAM VERB
    print ("Sending pkam: command");
    await writeCommand('pkam:$pkamDigest', log:false);
    response = await read(timeoutMillis:1000);
    print('pkam verb response $response');
    assert(response.contains('data:success'));
  }

  Future<void> clear() async {
    // queue.clear();
  }

  /// Handles responses from the remote secondary, adds to [_queue] for processing in [read] method
  /// Throws a [BufferOverFlowException] if buffer is unable to hold incoming data
  Future<void> _messageHandler(data) async {
    String result;
    if (!_buffer.isOverFlow(data)) {
      // skip @ prompt. byte code for @ is 64
      if (data.length == 1 && data.first == 64) {
        return;
      }
      //ignore prompt(@ or @<atSign>@) after '\n'. byte code for \n is 10
      if (data.last == 64 && data.contains(10)) {
        data = data.sublist(0, data.lastIndexOf(10) + 1);
        _buffer.append(data);
      } else if (data.length > 1 && data.first == 64 && data.last == 64) {
        // pol responses do not end with '\n'. Add \n for buffer completion
        _buffer.append(data);
        _buffer.addByte(10);
      } else {
        _buffer.append(data);
      }
    } else {
      _buffer.clear();
      throw BufferOverFlowException('Buffer overflow on outbound connection');
    }
    if (_buffer.isEnd()) {
      result = utf8.decode(_buffer.getData());
      result = result.trim();
      _buffer.clear();
      _queue.add(result);
    }
  }

  /// A message which is returned from [read] if throwTimeoutException is set to false
  static String readTimedOutMessage = 'E2E_SIMPLE_SOCKET_HANDLER_TIMED_OUT';

  Future<String> read({bool log = true, int timeoutMillis = 4000, bool throwTimeoutException = true}) async {
    String result;

    // Wait this many milliseconds between checks on the queue
    var loopDelay=250;

    // Check every loopDelay milliseconds until we get a response or timeoutMillis have passed.
    var loopCount = (timeoutMillis / loopDelay).round();
    for (var i = 0; i < loopCount; i++) {
      await Future.delayed(Duration(milliseconds: loopDelay));
      var queueLength = _queue.length;
      if (queueLength > 0) {
        result = _queue.removeFirst();
        if (log) {
          print("Response: $result");
        }
        // Got a response, let's return it
        return result;
      }
    }
    // No response - either throw a timeout exception or return the canned readTimedOutMessage
    if (throwTimeoutException) {
      throw AtTimeoutException ("No response from $host:$port ($atSign) after ${timeoutMillis/1000} seconds");
    } else {
      print ("read(): No response after $timeoutMillis milliseconds");
      return readTimedOutMessage;
    }
  }
}
/// Simple data-holding class which adds its instances into [atSignConfigMap]
class _AtSignConfig {
  String atSign;
  String host;
  int port;

  /// Creates and adds to [atSignConfigMap] or throws [_AtSignAlreadyAddedException] if we've already got it.
  _AtSignConfig(this.atSign, this.host, this.port) {
    if (atSignConfigMap.containsKey(atSign)) {
      throw _AtSignAlreadyAddedException("AtSignConfig for $atSign has already been created");
    }
    atSignConfigMap[atSign] = this;
  }
}

/// Thrown when an [_AtSignConfig] has already been created for a given atSign
class _AtSignAlreadyAddedException extends AtException {
  _AtSignAlreadyAddedException(message) : super(message);
}

/// Thrown when attempting to make a [SimpleOutboundSocketHandler] for an atSign for which we don't have an [_AtSignConfig]
class _NoSuchAtSignException extends AtException {
  _NoSuchAtSignException(message) : super(message);
}

bool _yamlLoaded = false;
// Called lazily by [getSocketHandler]
void _loadTheYaml() {
  if (_yamlLoaded) {
    return;
  }

  _yamlLoaded = true;

  _AtSignConfig(
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'],
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'],
      ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port']);

  _AtSignConfig(
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'],
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'],
      ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port']);

  /// TODO Ideally instead of the current config.yaml we'd have yaml like this
  ///   at_sign_configs:
  ///     cicd1:
  ///       host: example.com
  ///       port: 1234
  ///     cicd2:
  ///       host: example.com
  ///       port: 1234
  ///     ... etc
}

extension Utils on SimpleOutboundSocketHandler {
  Future<String> getVersion() async {
    await writeCommand('info\n');
    var version = await read();
    version = version.replaceAll('data:', '');
    // Since secondary version has gha<number> appended, remove the gha number from version
    // Hence using split.
    var versionStr = jsonDecode(version)['version'].split('+')[0];
    return versionStr;
  }
}
