import 'dart:math';

import 'package:at_commons/at_commons.dart';
import 'package:at_end2end_test/conf/config_util.dart';
import 'pkam_utils.dart';

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:at_utils/at_logger.dart';

const int maxRetryCount = 10;

AtSignLogger logger = AtSignLogger('e2e_test_utils');

/// Contains all [_AtSignConfig] instances we know about so we can avoid loads of boilerplate elsewhere
// ignore: library_private_types_in_public_api
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
Future<SimpleOutboundConnection> getSocketHandler(String atSign) async {
  _loadTheYaml();

  _AtSignConfig? asc = atSignConfigMap[atSign];
  if (asc == null) {
    throw _NoSuchAtSignException('$atSign not configured');
  }

  // ignore: prefer_typing_uninitialized_variables
  // ignore: prefer_typing_uninitialized_variables
  var handler;
  switch (asc.connectionType!) {
    case _ConnectionTypeEnum.socket:
      handler = SimpleOutboundSocketConnection(asc.host, asc.port, atSign);
      break;
    case _ConnectionTypeEnum.websocket:
      handler = SimpleOutboundWebsocketConnection(asc.host, asc.port, atSign);
      break;
  }

  await handler.connect();
  handler.startListening();
  await handler.sendFromAndPkam();

  return handler;
}

/// A simple wrapper around a socket for @ protocol communication.
/// A simple wrapper around a socket for @ protocol communication.
abstract class SimpleOutboundConnection {
  late Queue _queue;
  final _buffer = ByteBuffer(capacity: 10240000);

  String host;
  int port;
  String atSign;
  SimpleOutboundConnection(this.host, this.port, this.atSign) {
    _queue = Queue();
  }

  void close();
  Future<void> connect();
  void startListening();
  Future<void> writeCommand(String command, {bool log = true});
  Future<void> sendFromAndPkam();

  Future<void> clear() async {
    _queue.clear();
  }

  Future<String> read(
      {bool log = true,
      int timeoutMillis = 4000,
      bool throwTimeoutException = true}) async {
    String result;
    // Wait this many milliseconds between checks on the queue
    var loopDelay = 250;
    bool first = true;
    var loopCount = (timeoutMillis / loopDelay).round();
    for (var i = 0; i < loopCount; i++) {
      if (!first) {
        await Future.delayed(Duration(milliseconds: loopDelay));
      }
      first = false;
      var queueLength = _queue.length;
      if (queueLength > 0) {
        result = _queue.removeFirst();
        if (log) {
          print("Response: $result");
        }
        return result;
      }
    }
    // No response - either throw a timeout exception or return the canned readTimedOutMessage
    if (throwTimeoutException) {
      throw AtTimeoutException(
          "No response from $host:$port ($atSign) after ${timeoutMillis / 1000} seconds");
    } else {
      print("read(): No response after $timeoutMillis milliseconds");
      return readTimedOutMessage;
    }
  }

  final int newLineCodeUnit = 10;
  final int atCharCodeUnit = 64;

  /// Handles responses from the remote secondary, adds to [_queue] for processing in [read] method
  /// Throws a [BufferOverFlowException] if buffer is unable to hold incoming data
  /// Handles responses from the remote secondary for both socket and WebSocket connections.
  /// Adds responses to [_queue] for processing in the [read] method.
  /// Throws a [BufferOverFlowException] if buffer is unable to hold incoming data.
  Future<void> _messageHandler(dynamic data) async {
    if (data is String) {
      if (data == '@' || data.isEmpty) {
        return;
      }
      int lastIndexOfNewLineCharacter = data.lastIndexOf('\n');
      data = data.substring(0, lastIndexOfNewLineCharacter);
      _queue.add(data);
    } else if (data is List<int>) {
      // Handle raw socket data
      _checkBufferOverFlow(data);

      // Loop through the data and process it
      for (int element = 0; element < data.length; element++) {
        if (data[element] == newLineCodeUnit) {
          String result = utf8.decode(_buffer.getData().toList());
          result = _stripPrompt(result);
          _buffer.clear();
          _queue.add(result);
        } else {
          _buffer.addByte(data[element]);
        }
      }
    } else {
      throw UnsupportedError(
          'Unsupported data type received: ${data.runtimeType}');
    }
  }

  void _checkBufferOverFlow(dynamic data) {
    if (_buffer.isOverFlow(data)) {
      int bufferLength = (_buffer.length() + data.length) as int;
      _buffer.clear();
      throw BufferOverFlowException(
          'data length exceeded the buffer limit. Data length : $bufferLength and Buffer capacity ${_buffer.capacity}');
    }
  }

  String _stripPrompt(String result) {
    var colonIndex = result.indexOf(':');
    if (colonIndex == -1) {
      return result;
    }
    var responsePrefix = result.substring(0, colonIndex);
    var response = result.substring(colonIndex);
    if (responsePrefix.contains('@')) {
      responsePrefix =
          responsePrefix.substring(responsePrefix.lastIndexOf('@') + 1);
    }
    return '$responsePrefix$response';
  }

  static String readTimedOutMessage = 'E2E_SIMPLE_SOCKET_HANDLER_TIMED_OUT';
}

class SimpleOutboundSocketConnection extends SimpleOutboundConnection {
  SecureSocket? socket;

  SimpleOutboundSocketConnection(String host, int port, String atSign)
      : super(host, port, atSign);

  @override
  void close() {
    print("Closing SimpleOutboundSocketConnection for $atSign ($host:$port)");
    socket?.destroy();
  }

  @override
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
    throw Exception(
        "Failed to connect to $host:$port after $retryCount attempts");
  }

  @override
  void startListening() {
    socket?.listen(_messageHandler);
  }

  @override
  Future<void> writeCommand(String command, {bool log = true}) async {
    if (log) {
      print('command sent: $command');
    }
    if (!command.endsWith('\n')) {
      command = '$command\n';
    }
    socket?.write(command);
  }

  @override
  Future<void> sendFromAndPkam() async {
    await writeCommand('from:$atSign:clientConfig:{"version":"3.0.38"}');
    var response = await read(timeoutMillis: 5000);
    response = response.replaceAll('data:', '');
    String pkamDigest = await generatePKAMDigest(atSign, response);

    await writeCommand('pkam:$pkamDigest', log: false);
    response = await read(timeoutMillis: 5000);
    print('pkam verb response $response');
    assert(response.contains('data:success'));
  }
}

class SimpleOutboundWebsocketConnection extends SimpleOutboundConnection {
  WebSocket? websocket;

  SimpleOutboundWebsocketConnection(String host, int port, String atSign)
      : super(host, port, atSign);

  @override
  void close() {
    print(
        "Closing SimpleOutboundWebsocketConnection for $atSign ($host:$port)");
    websocket?.close();
  }

  @override
  Future<void> connect() async {
    try {
      Random random = Random();
      String key =
          base64.encode(List<int>.generate(8, (_) => random.nextInt(256)));

      SecurityContext context = SecurityContext(withTrustedRoots: true);
      context.setAlpnProtocols(['http/1.1'], false);
      HttpClient client = HttpClient(context: context);

      Uri uri = Uri.parse("https://$host:$port/ws");
      HttpClientRequest request = await client.getUrl(uri);
      request.headers.add('Connection', 'upgrade');
      request.headers.add('Upgrade', 'websocket');
      request.headers.add('sec-websocket-version', '13');
      request.headers.add('sec-websocket-key', key);

      HttpClientResponse response = await request.close();
      Socket socket = await response.detachSocket();

      websocket = WebSocket.fromUpgradedSocket(
        socket,
        serverSide: false,
      );

      print('WebSocket connection established for $atSign ($host:$port)');
    } catch (e) {
      throw AtException(
          'Failed to establish WebSocket connection: ${e.toString()}');
    }
  }

  @override
  void startListening() {
    websocket?.listen(_messageHandler);
  }

  @override
  Future<void> writeCommand(String command, {bool log = true}) async {
    if (log) {
      print('command sent: $command');
    }
    if (!command.endsWith('\n')) {
      command = '$command\n';
    }
    websocket?.add(command);
  }

  @override
  Future<void> sendFromAndPkam() async {
    await writeCommand('from:$atSign:clientConfig:{"version":"3.0.38"}');
    var response = await read(timeoutMillis: 5000);
    response = response.replaceAll('data:', '');
    String pkamDigest = await generatePKAMDigest(atSign, response);

    await writeCommand('pkam:$pkamDigest', log: false);
    response = await read(timeoutMillis: 5000);
    print('pkam verb response $response');
    assert(response.contains('data:success'));
  }
}

enum _ConnectionTypeEnum {
  socket,
  websocket,
}

/// Simple data-holding class which adds its instances into [atSignConfigMap]
class _AtSignConfig {
  String atSign;
  String host;
  int port;
  _ConnectionTypeEnum? connectionType;

  /// Creates and adds to [atSignConfigMap] or throws [_AtSignAlreadyAddedException] if we've already got it.
  _AtSignConfig(this.atSign, this.host, this.port, this.connectionType) {
    connectionType ??= _ConnectionTypeEnum.socket;
    if (atSignConfigMap.containsKey(atSign)) {
      throw _AtSignAlreadyAddedException(
          "AtSignConfig for $atSign has already been created");
    }
    atSignConfigMap[atSign] = this;
  }
}

/// Thrown when an [_AtSignConfig] has already been created for a given atSign
class _AtSignAlreadyAddedException extends AtException {
  _AtSignAlreadyAddedException(String message) : super(message);
}

/// Thrown when attempting to make a [SimpleOutboundSocketHandler] for an atSign for which we don't have an [_AtSignConfig]
class _NoSuchAtSignException extends AtException {
  _NoSuchAtSignException(String message) : super(message);
}

bool _yamlLoaded = false;
// Called lazily by [getSocketHandler]
void _loadTheYaml() {
  if (_yamlLoaded) {
    return;
  }

  _yamlLoaded = true;

  String? connTypeStr1;
  _ConnectionTypeEnum? connType1;
  connTypeStr1 = ConfigUtil.getYaml()!['first_atsign_server']
      ['first_atsign_connection_type'];
  if (connTypeStr1 != null) {
    connType1 = _ConnectionTypeEnum.values.byName(connTypeStr1);
  }
  _AtSignConfig(
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_name'],
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_url'],
    ConfigUtil.getYaml()!['first_atsign_server']['first_atsign_port'],
    connType1,
  );

  String? connTypeStr2;
  _ConnectionTypeEnum? connType2;
  connTypeStr2 = ConfigUtil.getYaml()!['second_atsign_server']
      ['second_atsign_connection_type'];
  if (connTypeStr2 != null) {
    connType2 = _ConnectionTypeEnum.values.byName(connTypeStr2);
  }
  _AtSignConfig(
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_name'],
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_url'],
    ConfigUtil.getYaml()!['second_atsign_server']['second_atsign_port'],
    connType2,
  );

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

extension Utils on SimpleOutboundConnection {
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
