import 'dart:io';
import 'package:at_secondary/src/connection/inbound/inbound_connection_impl.dart';
import 'package:at_secondary/src/connection/outbound/outbound_client_manager.dart';
import 'package:at_secondary/src/connection/outbound/outbound_connection_impl.dart';
import 'package:at_secondary/src/server/at_secondary_impl.dart';
import 'package:at_secondary/src/server/server_context.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    var serverContext = AtSecondaryContext();
    serverContext.inboundIdleTimeMillis = 5000;
    serverContext.outboundIdleTimeMillis = 3000;
    AtSecondaryServerImpl
        .getInstance()
        .serverContext = serverContext;
  });

  group('A group of outbound client manager tests', () {
    test('test outbound client manager - create new client ', () {
      var dummySocket;
      var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
      var clientManager = OutboundClientManager.getInstance();
      clientManager.init(5);
      var outBoundClient = clientManager.getClient('bob', inboundConnection)!;
      expect(outBoundClient.toAtSign, 'bob');
      expect(clientManager.getActiveConnectionSize(), 1);
    });

    // test('test outbound client manager - get existing client ', () {
    //   var dummySocket = DummySocket(1);
    //   var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(5);
    //   var outBoundClient_1 =
    //       clientManager.getClient('bob', inboundConnection, isHandShake: false)!;
    //   expect(outBoundClient_1.toAtSign, 'bob');
    //   expect(clientManager.getActiveConnectionSize(), 1);
    //   var outBoundClient_2 =
    //       clientManager.getClient('bob', inboundConnection, isHandShake: false)!;
    //   expect(outBoundClient_1.toAtSign == outBoundClient_2.toAtSign, true);
    //   expect(clientManager.getActiveConnectionSize(), 1);
    // });

    // test('test outbound client manager - add multiple clients ', () {
    //   var dummySocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(5);
    //   var outBoundClient_1 =
    //       clientManager.getClient('alice', inboundConnection_1)!;
    //   var outBoundClient_2 =
    //       clientManager.getClient('bob', inboundConnection_2)!;
    //   expect(outBoundClient_1.toAtSign, 'alice');
    //   expect(outBoundClient_2.toAtSign, 'bob');
    //   expect(clientManager.getActiveConnectionSize(), 2);
    // });

    // test('test outbound client manager - capacity exceeded ', () {
    //   //var dummySocket_1 = DummySocket(1);
    //   var dummySocket_2 = DummySocket(2);
    //   var dummySocket_3 = DummySocket(3);
    //   var inboundConnection_1 = InboundConnectionImpl(dummySocket_1, 'aaa');
    //   var inboundConnection_2 = InboundConnectionImpl(dummySocket_2, 'bbb');
    //   var inboundConnection_3 = InboundConnectionImpl(dummySocket_3, 'ccc');
    //   var clientManager = OutboundClientManager.getInstance();
    //   clientManager.init(2);
    //   clientManager.getClient('alice', inboundConnection_1);
    //   clientManager.getClient('bob', inboundConnection_2);
    //   expect(
    //       () => clientManager.getClient('charlie', inboundConnection_3),
    //       throwsA(predicate((dynamic e) =>
    //           e is OutboundConnectionLimitException &&
    //           e.message == 'max limit reached on outbound pool')));
    // });

    test(
        'test outbound client manager - inbound is closed, outbound client is invalid',
            () {
          var dummySocket;
          var inboundConnection = InboundConnectionImpl(dummySocket, 'aaa');
          var clientManager = OutboundClientManager.getInstance();
          clientManager.init(5);
          var outBoundClient_1 = clientManager.getClient(
              'bob', inboundConnection)!;
          inboundConnection.close();
          expect(outBoundClient_1.isInValid(), true);
        });

    test(
        'test outbound client manager - outbound client is closed, inbound is still valid',
            () {
          var dummySocket_1, dummySocket_2;
          var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
          var clientManager = OutboundClientManager.getInstance();
          clientManager.init(5);
          var outBoundClient_1 = clientManager.getClient(
              'bob', inboundConnection)!;
          outBoundClient_1.outboundConnection =
              OutboundConnectionImpl(dummySocket_2, 'bob');
          outBoundClient_1.close();
          expect(inboundConnection.isInValid(), false);
        });

    test(
        'test outbound client manager - outbound client is idle and becomes invalid',
            () {
          var dummySocket_1, dummySocket_2;
          var inboundConnection = InboundConnectionImpl(dummySocket_1, 'aaa');
          var clientManager = OutboundClientManager.getInstance();
          clientManager.init(5);
          var outBoundClient_1 = clientManager.getClient(
              'bob', inboundConnection)!;
          outBoundClient_1.outboundConnection =
              OutboundConnectionImpl(dummySocket_2, 'bob');
          sleep(Duration(seconds: 4));
          expect(outBoundClient_1.isInValid(), true);
        });
  });
}

// class DummySocket implements Socket {
//  var clientCounter;
//
//  DummySocket(this.clientCounter);
//
//  @override
//  InternetAddress get remoteAddress =>
//      InternetAddress('192.168.1.${clientCounter}');
//
//  @override
//  int get remotePort => 6460 + clientCounter as int;
//
//  @override
//  late Encoding encoding;
//
//  @override
//  void add(List<int> data) {
//    // TODO: implement add
//  }
//
//  @override
//  void addError(Object error, [StackTrace? stackTrace]) {
//    // TODO: implement addError
//  }
//
//  @override
//  Future addStream(Stream<List<int>> stream) {
//    // TODO: implement addStream
//    return null;
//  }
//
//  @override
//  // TODO: implement address
//  InternetAddress get address => null;
//
//  @override
//  Future<bool> any(bool Function(Uint8List element) test) {
//    // TODO: implement any
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> asBroadcastStream(
//      {void Function(StreamSubscription<Uint8List> subscription)? onListen,
//      void Function(StreamSubscription<Uint8List> subscription)? onCancel}) {
//    // TODO: implement asBroadcastStream
//    return null;
//  }
//
//  @override
//  Stream<E> asyncExpand<E>(Stream<E> Function(Uint8List event) convert) {
//    // TODO: implement asyncExpand
//    return null;
//  }
//
//  @override
//  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List event) convert) {
//    // TODO: implement asyncMap
//    return null;
//  }
//
//  @override
//  Stream<R> cast<R>() {
//    // TODO: implement cast
//    return null;
//  }
//
//  @override
//  Future close() {
//    // TODO: implement close
//    return null;
//  }
//
//  @override
//  Future<bool> contains(Object? needle) {
//    // TODO: implement contains
//    return null;
//  }
//
//  @override
//  void destroy() {
//    // TODO: implement destroy
//  }
//
//  @override
//  Stream<Uint8List> distinct(
//      [bool Function(Uint8List previous, Uint8List next)? equals]) {
//    // TODO: implement distinct
//    return null;
//  }
//
//  @override
//  // TODO: implement done
//  Future get done => null;
//
//  @override
//  Future<E> drain<E>([E? futureValue]) {
//    // TODO: implement drain
//    return null;
//  }
//
//  @override
//  Future<Uint8List> elementAt(int index) {
//    // TODO: implement elementAt
//    return null;
//  }
//
//  @override
//  Future<bool> every(bool Function(Uint8List element) test) {
//    // TODO: implement every
//    return null;
//  }
//
//  @override
//  Stream<S> expand<S>(Iterable<S> Function(Uint8List element) convert) {
//    // TODO: implement expand
//    return null;
//  }
//
//  @override
//  // TODO: implement first
//  Future<Uint8List> get first => null;
//
//  @override
//  Future<Uint8List> firstWhere(bool Function(Uint8List element) test,
//      {Uint8List Function()? orElse}) {
//    // TODO: implement firstWhere
//    return null;
//  }
//
//  @override
//  Future flush() {
//    // TODO: implement flush
//    return Future.value(null);
//  }
//
//  @override
//  Future<S> fold<S>(
//      S initialValue, S Function(S previous, Uint8List element) combine) {
//    // TODO: implement fold
//    return Future.value(null);
//  }
//
//  @override
//  Future forEach(void Function(Uint8List element) action) {
//    // TODO: implement forEach
//    return Future.value(null);
//  }
//
//  @override
//  Uint8List getRawOption(RawSocketOption option) {
//    // TODO: implement getRawOption
//    return ;
//  }
//
//  @override
//  Stream<Uint8List> handleError(Function onError, {bool Function(Error)? test}) {
//    // TODO: implement handleError
//    return null;
//  }
//
//  @override
//  // TODO: implement isBroadcast
//  bool get isBroadcast => null;
//
//  @override
//  // TODO: implement isEmpty
//  Future<bool> get isEmpty => null;
//
//  @override
//  Future<String> join([String separator = '']) {
//    // TODO: implement join
//    return null;
//  }
//
//  @override
//  // TODO: implement last
//  Future<Uint8List> get last => null;
//
//  @override
//  Future<Uint8List> lastWhere(bool Function(Uint8List element) test,
//      {Uint8List Function()? orElse}) {
//    // TODO: implement lastWhere
//    return null;
//  }
//
//  @override
//  // TODO: implement length
//  Future<int> get length => null;
//
//  @override
//  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
//      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
//    // TODO: implement listen
//    return null;
//  }
//
//  @override
//  Stream<S> map<S>(S Function(Uint8List event) convert) {
//    // TODO: implement map
//    return null;
//  }
//
//  @override
//  Future pipe(StreamConsumer<Uint8List> streamConsumer) {
//    // TODO: implement pipe
//    return null;
//  }
//
//  @override
//  // TODO: implement port
//  int get port => null;
//
//  @override
//  Future<Uint8List> reduce(
//      Uint8List Function(Uint8List previous, Uint8List element) combine) {
//    // TODO: implement reduce
//    return null;
//  }
//
//  @override
//  bool setOption(SocketOption option, bool enabled) {
//    // TODO: implement setOption
//    return null;
//  }
//
//  @override
//  void setRawOption(RawSocketOption option) {
//    // TODO: implement setRawOption
//  }
//
//  @override
//  // TODO: implement single
//  Future<Uint8List> get single => null;
//
//  @override
//  Future<Uint8List> singleWhere(bool Function(Uint8List element) test,
//      {Uint8List Function()? orElse}) {
//    // TODO: implement singleWhere
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> skip(int count) {
//    // TODO: implement skip
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) {
//    // TODO: implement skipWhile
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> take(int count) {
//    // TODO: implement take
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) {
//    // TODO: implement takeWhile
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> timeout(Duration timeLimit,
//      {void Function(EventSink<Uint8List> sink)? onTimeout}) {
//    // TODO: implement timeout
//    return null;
//  }
//
//  @override
//  Future<List<Uint8List>> toList() {
//    // TODO: implement toList
//    return null;
//  }
//
//  @override
//  Future<Set<Uint8List>> toSet() {
//    // TODO: implement toSet
//    return null;
//  }
//
//  @override
//  Stream<S> transform<S>(StreamTransformer<Uint8List, S> streamTransformer) {
//    // TODO: implement transform
//    return null;
//  }
//
//  @override
//  Stream<Uint8List> where(bool Function(Uint8List event) test) {
//    // TODO: implement where
//    return null;
//  }
//
//  @override
//  void write(Object? obj) {
//    // TODO: implement write
//  }
//
//  @override
//  void writeAll(Iterable objects, [String separator = '']) {
//    // TODO: implement writeAll
//  }
//
//  @override
//  void writeCharCode(int charCode) {
//    // TODO: implement writeCharCode
//  }
//
//  @override
//  void writeln([Object? obj = '']) {
//    // TODO: implement writeln
//  }
