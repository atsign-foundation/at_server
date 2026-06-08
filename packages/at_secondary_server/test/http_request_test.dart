import 'dart:convert';
import 'dart:io';

import 'package:at_base2e15/at_base2e15.dart';
import 'package:at_commons/at_commons.dart' hide StringBuffer;
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/server/http_request_handler.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import 'sync_unit_test.dart';
import 'test_utils.dart';

void main() async {
  late AtServerHttpRequestHandler handler;

  final Map<String, Map> mdMap = {};
  Future<void> putText(String key, String value) async {
    final AtMetaData atMetaData = AtMetaData.fromCommonsMetadata(
      Metadata()
        ..ttl = 1234
        ..ttr = 5,
      alice,
    );
    // If no value supplied, set the value to be the same as the key name
    AtData d = AtData()
      ..data = value
      ..metaData = atMetaData;
    await keyValueStore.put(key, d);
    mdMap[key] = SecondaryUtil.removeNulls(atMetaData.toJson())!;
  }

  Future<void> putBinary(String key, List<int> value) async {
    final AtMetaData atMetaData = AtMetaData.fromCommonsMetadata(
      Metadata()
        ..ttl = 1234
        ..ttr = 5
        ..isBinary = true,
      alice,
    );
    // If no value supplied, set the value to be the same as the key name
    AtData d = AtData()
      ..data = Base2e15.encode(value)
      ..metaData = atMetaData;
    await keyValueStore.put(key, d);
    mdMap[key] = SecondaryUtil.removeNulls(atMetaData.toJson())!;
  }

  FakeHttpRequest createRequest(String method, String path) {
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    final req = FakeHttpRequest(
        method, Uri.parse('https://alice.atservers.swarm/$path'));
    return req;
  }

  String keyFoo = 'public:foo$alice';
  String keyFooBar = 'public:foo.bar$alice';
  String keyFooBarBaz = 'public:foo.bar.baz$alice';
  String keyIndexHtml = 'public:index.html.foo.bar.baz$alice';
  String valueIndexHtml = '<body><h1>Hello, world!!!</h1></body>';
  String keyHiddenIndexHtml = 'public:_index.html.foo.bar.baz$alice';
  String valueHiddenIndexHtml = '<body><h1>Hidden worlds</h1></body>';
  String keyJpeg = 'public:some.jpg.assets.my_app$alice';
  List<int> valueJpeg = keyJpeg.codeUnits;
  String keyAac = 'public:some.aac.assets.my_app$alice';
  List<int> valueAac = keyAac.codeUnits;
  String keyGenericBinary = 'public:generic_binary.binaries.my_app$alice';
  List<int> valueGenericBinary = keyGenericBinary.codeUnits;

  setUp(() async {
    await verbTestsSetUp();
    handler = AtServerHttpRequestHandler(alice, keyValueStore);
    handler.logger.level = 'warning';
    await putText(keyFoo, keyFoo);
    await putText(keyFooBar, keyFooBar);
    await putText(keyFooBarBaz, keyFooBarBaz);
    await putText(keyIndexHtml, valueIndexHtml);
    await putText(keyHiddenIndexHtml, valueHiddenIndexHtml);
    await putBinary(keyJpeg, valueJpeg);
    await putBinary(keyAac, valueAac);
    await putBinary(keyGenericBinary, valueGenericBinary);
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  Future<void> check({
    required int expectedStatus,
    required dynamic expectedBody,
    required ContentType? expectedContentType,
    required String method,
    required String uri,
  }) async {
    final FakeHttpRequest request = createRequest(method, uri);
    await (handler.handle(request));
    expect(request.response.statusCode, expectedStatus);
    expect(request.response.headers.contentType?.mimeType,
        expectedContentType?.mimeType);
    expect(request.response.headers.contentType?.charset,
        expectedContentType?.charset);
    switch (request.response.statusCode) {
      case HttpStatus.ok:
        break;
      case HttpStatus.notFound:
        expectedBody = '404 Not Found';
        break;
      default:
        expectedBody = '';
    }
    if (expectedBody is List<int>) {
      expect(request.response.bodyAsBytes, expectedBody);
    } else {
      expect(request.response.bodyAsString, expectedBody);
    }
  }

  // For each key, try various permutations
  // - public:${key}@alice
  // - ${key}@alice
  // - public:${key}
  // - ${key}
  //
  // For each of the above, do a GET for data and another for metadata, and
  // one for both data and metadata
  Future<void> basicChecks({
    required int expectedStatus,
    required dynamic expectedBody,
    required ContentType? expectedContentType,
    required String method,
    required String key,
  }) async {
    if (key.startsWith('public:')) {
      key = key.replaceFirst('public:', '');
    }
    if (key.endsWith(atSign)) {
      key = key.substring(0, key.length - atSign.length);
    }
    String fullKey = handler.getKeyToLookup('public:$key$atSign');

    ContentType? metadataContentType;
    if (expectedContentType != null) {
      metadataContentType = ContentType.json;
    }
    // WITH public: prefix, WITH atSign suffix
    await check(
      expectedStatus: expectedStatus,
      expectedBody: expectedBody,
      expectedContentType: expectedContentType,
      method: method,
      uri: '/public:$key$atSign',
    );
    await check(
        expectedStatus: expectedStatus,
        expectedBody: jsonEncode(mdMap[fullKey]),
        expectedContentType: metadataContentType,
        method: method,
        uri: '/public:$key$atSign?at_rt=meta');

    // WITH public: prefix, WITHOUT atSign suffix
    await check(
        expectedStatus: expectedStatus,
        expectedBody: expectedBody,
        expectedContentType: expectedContentType,
        method: method,
        uri: '/public:$key');
    await check(
        expectedStatus: expectedStatus,
        expectedBody: jsonEncode(mdMap[fullKey]),
        expectedContentType: metadataContentType,
        method: method,
        uri: '/public:$key?at_rt=meta');

    // WITHOUT public: prefix, WITH atSign suffix
    await check(
        expectedStatus: expectedStatus,
        expectedBody: expectedBody,
        expectedContentType: expectedContentType,
        method: method,
        uri: '/$key$atSign');
    await check(
        expectedStatus: expectedStatus,
        expectedBody: jsonEncode(mdMap[fullKey]),
        expectedContentType: metadataContentType,
        method: method,
        uri: '/$key$atSign?at_rt=meta');

    // WITHOUT public: prefix, WITHOUT atSign suffix
    await check(
        expectedStatus: expectedStatus,
        expectedBody: expectedBody,
        expectedContentType: expectedContentType,
        method: method,
        uri: '/$key');
    await check(
        expectedStatus: expectedStatus,
        expectedBody: jsonEncode(mdMap[fullKey]),
        expectedContentType: metadataContentType,
        method: method,
        uri: '/$key?at_rt=meta');
  }

  group('http basic checks status 200', () {
    test('get fake jpeg', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueJpeg,
          expectedContentType: ContentType.parse('image/jpeg; charset=utf-8'),
          method: 'GET',
          key: keyJpeg);
    });
    test('get fake aac', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueAac,
          expectedContentType: ContentType.parse('audio/aac; charset=utf-8'),
          method: 'GET',
          key: keyAac);
    });
    test('get generic binary', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueGenericBinary,
          expectedContentType:
              ContentType.parse('application/octet-stream; charset=utf-8'),
          method: 'GET',
          key: keyGenericBinary);
    });

    test('get public key', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: keyFoo,
          expectedContentType: ContentType.parse('text/plain; charset=utf-8'),
          method: 'GET',
          key: 'foo');
    });

    test('get public key with namespace', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: keyFooBar,
          expectedContentType: ContentType.parse('text/plain; charset=utf-8'),
          method: 'GET',
          key: 'foo.bar');
    });

    test('get public key with namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: keyFooBarBaz,
          expectedContentType: ContentType.parse('text/plain; charset=utf-8'),
          method: 'GET',
          key: 'foo.bar.baz');
    });

    test('get public key with many namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueIndexHtml,
          expectedContentType: ContentType.parse('text/html; charset=utf-8'),
          method: 'GET',
          key: 'index.html.foo.bar.baz');
    });

    test('get public hidden key with many namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueHiddenIndexHtml,
          expectedContentType: ContentType.parse('text/html; charset=utf-8'),
          method: 'GET',
          key: '_index.html.foo.bar.baz');
    });
  });
  group('http checks using path and dot separators status 200', () {
    test('get public key with namespaces using path and dots', () async {
      for (final k in [
        'baz/bar/foo/html/index',
        'baz/bar/foo/index.html',
        'bar.baz/index.html.foo',
        'foo.bar.baz/index.html',
        'baz/bar/index.html.foo',
        'baz/index.html.foo.bar',
        'index.html.foo.bar.baz',
      ]) {
        await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueIndexHtml,
          expectedContentType: ContentType.parse('text/html; charset=utf-8'),
          method: 'GET',
          key: k,
        );
      }
    });
    test('get public hidden key with namespaces using path and dots', () async {
      for (final k in [
        'baz/bar/foo/html/_index',
        'baz/bar/foo/_index.html',
        'bar.baz/_index.html.foo',
        'foo.bar.baz/_index.html',
        'baz/bar/_index.html.foo',
        'baz/_index.html.foo.bar',
        '_index.html.foo.bar.baz',
      ]) {
        await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: valueHiddenIndexHtml,
          expectedContentType: ContentType.parse('text/html; charset=utf-8'),
          method: 'GET',
          key: k,
        );
      }
    });
  });
  group('http checks status 404, 400', () {
    test('non-existent public keys', () async {
      await basicChecks(
        expectedStatus: HttpStatus.notFound,
        expectedBody: '404 Not Found',
        expectedContentType: null,
        method: 'GET',
        key: 'nope',
      );
    });
    test('self key', () async {
      await basicChecks(
        expectedStatus: HttpStatus.notFound,
        expectedBody: '404 Not Found',
        expectedContentType: null,
        method: 'GET',
        key: '$alice:foo.bar$alice',
      );
    });
    test('shared key', () async {
      await basicChecks(
        expectedStatus: HttpStatus.notFound,
        expectedBody: '404 Not Found',
        expectedContentType: null,
        method: 'GET',
        key: '$bob:foo.bar$alice',
      );
    });
    test('HEAD', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        expectedContentType: null,
        method: 'HEAD',
        key: keyFooBar,
      );
    });
    test('PUT', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        expectedContentType: null,
        method: 'PUT',
        key: keyFooBar,
      );
    });
    test('POST', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        expectedContentType: null,
        method: 'POST',
        key: keyFooBar,
      );
    });
    test('DELETE', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        expectedContentType: null,
        method: 'DELETE',
        key: keyFooBar,
      );
    });
    test('Impossibly long key', () async {
      StringBuffer b = StringBuffer('foo');
      for (int i = 0; i < 10000; i++) {
        b.write('.bar.baz');
      }
      await basicChecks(
        expectedStatus: HttpStatus.badRequest,
        expectedBody: '',
        expectedContentType: null,
        method: 'GET',
        key: b.toString(),
      );
    });
  });
}

class FakeHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, List<String>> _headers = {};

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    name = name.toLowerCase();
    if (!_headers.containsKey(name)) {
      _headers[name] = [value.toString()];
    } else {
      _headers[name]!.add(value.toString());
    }
  }

  @override
  List<String>? operator [](String name) {
    return _headers[name.toLowerCase()];
  }

  @override
  set contentType(ContentType? ct) =>
      add(HttpHeaders.contentTypeHeader, ct?.toString() ?? '');

  @override
  ContentType? get contentType {
    var values = _headers[HttpHeaders.contentTypeHeader];
    if (values != null) {
      return ContentType.parse(values[0]);
    } else {
      return null;
    }
  }
}

class FakeHttpResponse extends Fake implements HttpResponse {
  final List<int> _data = [];

  List<int> get bodyAsBytes => _data;

  String get bodyAsString => String.fromCharCodes(_data);
  bool _isClosed = false;

  @override
  late int statusCode;

  @override
  FakeHttpHeaders headers = FakeHttpHeaders();

  @override
  void add(List<int> data) {
    _data.addAll(data);
  }

  @override
  void write(Object? object) {
    if (_isClosed) {
      throw StateError('FakeHttpResponse is closed');
    }
    if (object != null) {
      add(object.toString().codeUnits);
    }
  }

  @override
  Future close() async {
    _isClosed = true;
  }
}

class FakeHttpRequest extends Fake implements HttpRequest {
  @override
  final String method;
  @override
  final Uri uri;

  @override
  Uri get requestedUri => uri;
  @override
  late final FakeHttpResponse response;

  FakeHttpRequest(this.method, this.uri) {
    response = FakeHttpResponse();
  }
}
