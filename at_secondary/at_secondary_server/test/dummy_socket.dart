import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

/// A dummy socket class for passing a socket object in unit tests
class DummySocket extends Socket {
  static final DummySocket _singleton = DummySocket._internal();

  DummySocket._internal();

  factory DummySocket.getInstance() {
    return _singleton;
  }

  @override
  late Encoding encoding;

  static get stream => null;

  @override
  void add(List<int> data) {
    // TODO: implement add
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // TODO: implement addError
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    // TODO: implement addStream
    throw UnimplementedError();
  }

  @override
  // TODO: implement address
  InternetAddress get address => throw UnimplementedError();

  @override
  Future<bool> any(bool Function(Uint8List element) test) {
    // TODO: implement any
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> asBroadcastStream({onListen, onCancel}) {
    // TODO: implement asBroadcastStream
    throw UnimplementedError();
  }

  @override
  Stream<E> asyncExpand<E>(Stream<E>? Function(Uint8List event) convert) {
    // TODO: implement asyncExpand
    throw UnimplementedError();
  }

  @override
  Stream<E> asyncMap<E>(FutureOr<E> Function(Uint8List event) convert) {
    // TODO: implement asyncMap
    throw UnimplementedError();
  }

  @override
  Stream<R> cast<R>() {
    // TODO: implement cast
    throw UnimplementedError();
  }

  @override
  Future close() {
    // TODO: implement close
    throw UnimplementedError();
  }

  @override
  Future<bool> contains(Object? needle) {
    // TODO: implement contains
    throw UnimplementedError();
  }

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  Stream<Uint8List> distinct(
      [bool Function(Uint8List previous, Uint8List next)? equals]) {
    // TODO: implement distinct
    throw UnimplementedError();
  }

  @override
  // TODO: implement done
  Future get done => throw UnimplementedError();

  @override
  Future<E> drain<E>([E? futureValue]) {
    // TODO: implement drain
    throw UnimplementedError();
  }

  @override
  Future<Uint8List> elementAt(int index) {
    // TODO: implement elementAt
    throw UnimplementedError();
  }

  @override
  Future<bool> every(bool Function(Uint8List element) test) {
    // TODO: implement every
    throw UnimplementedError();
  }

  @override
  Stream<S> expand<S>(Iterable<S> Function(Uint8List element) convert) {
    // TODO: implement expand
    throw UnimplementedError();
  }

  @override
  // TODO: implement first
  Future<Uint8List> get first => throw UnimplementedError();

  @override
  Future<Uint8List> firstWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    // TODO: implement firstWhere
    throw UnimplementedError();
  }

  @override
  Future flush() {
    // TODO: implement flush
    throw UnimplementedError();
  }

  @override
  Future<S> fold<S>(
      S initialValue, S Function(S previous, Uint8List element) combine) {
    // TODO: implement fold
    throw UnimplementedError();
  }

  @override
  Future forEach(void Function(Uint8List element) action) {
    // TODO: implement forEach
    throw UnimplementedError();
  }

  @override
  Uint8List getRawOption(RawSocketOption option) {
    // TODO: implement getRawOption
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> handleError(Function onError,
      {bool Function(Error)? test}) {
    // TODO: implement handleError
    throw UnimplementedError();
  }

  @override
  // TODO: implement isBroadcast
  bool get isBroadcast => throw UnimplementedError();

  @override
  // TODO: implement isEmpty
  Future<bool> get isEmpty => throw UnimplementedError();

  @override
  Future<String> join([String separator = ""]) {
    // TODO: implement join
    throw UnimplementedError();
  }

  @override
  // TODO: implement last
  Future<Uint8List> get last => throw UnimplementedError();

  @override
  Future<Uint8List> lastWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    // TODO: implement lastWhere
    throw UnimplementedError();
  }

  @override
  // TODO: implement length
  Future<int> get length => throw UnimplementedError();

  @override
  Stream<S> map<S>(S Function(Uint8List event) convert) {
    // TODO: implement map
    throw UnimplementedError();
  }

  @override
  Future pipe(StreamConsumer<Uint8List> streamConsumer) {
    // TODO: implement pipe
    throw UnimplementedError();
  }

  @override
  // TODO: implement port
  int get port => throw UnimplementedError();

  @override
  Future<Uint8List> reduce(
      Uint8List Function(Uint8List previous, Uint8List element) combine) {
    // TODO: implement reduce
    throw UnimplementedError();
  }

  @override
  InternetAddress get remoteAddress {
    return InternetAddress('127.0.0.1');
  }

  @override
  int get remotePort {
    return 9000;
  }

  @override
  bool setOption(SocketOption option, bool enabled) {
    // TODO: implement setOption
    throw UnimplementedError();
  }

  @override
  void setRawOption(RawSocketOption option) {
    // TODO: implement setRawOption
  }

  @override
// TODO: implement single
  Future<Uint8List> get single => throw UnimplementedError();

  @override
  Future<Uint8List> singleWhere(bool Function(Uint8List element) test,
      {Uint8List Function()? orElse}) {
    // TODO: implement singleWhere
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> skip(int count) {
    // TODO: implement skip
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> skipWhile(bool Function(Uint8List element) test) {
    // TODO: implement skipWhile
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> take(int count) {
    // TODO: implement take
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> takeWhile(bool Function(Uint8List element) test) {
    // TODO: implement takeWhile
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> timeout(Duration timeLimit,
      {void Function(EventSink<Uint8List> sink)? onTimeout}) {
    // TODO: implement timeout
    throw UnimplementedError();
  }

  @override
  Future<List<Uint8List>> toList() {
    // TODO: implement toList
    throw UnimplementedError();
  }

  @override
  Future<Set<Uint8List>> toSet() {
    // TODO: implement toSet
    throw UnimplementedError();
  }

  @override
  Stream<S> transform<S>(StreamTransformer<Uint8List, S> streamTransformer) {
    // TODO: implement transform
    throw UnimplementedError();
  }

  @override
  Stream<Uint8List> where(bool Function(Uint8List event) test) {
    // TODO: implement where
    throw UnimplementedError();
  }

  @override
  void write(Object? object) {
    // TODO: implement write
  }

  @override
  void writeAll(Iterable objects, [String separator = ""]) {
    // TODO: implement writeAll
  }

  @override
  void writeCharCode(int charCode) {
    // TODO: implement writeCharCode
  }

  @override
  void writeln([Object? object = ""]) {
    // TODO: implement writeln
  }

  dynamic onListen(var data) {
    print('_Inside OnListen ${utf8.decode(data)}');
  }

  dynamic onCancel(var data) {
    print('_Inside OnCancel ${utf8.decode(data)}');
  }

  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    // TODO: implement listen
    throw UnimplementedError();
  }
}
