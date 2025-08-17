import 'dart:convert';
import 'dart:io';

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
  Future<void> put(String key, {String? value}) async {
    final AtMetaData atMetaData = AtMetaData.fromCommonsMetadata(
      Metadata()
        ..ttl = 1234
        ..ttr = 5,
      alice,
    );
    // If no value supplied, set the value to be the same as the key name
    AtData d = AtData()
      ..data = value ?? key
      ..metaData = atMetaData;
    await secondaryKeyStore.put(key, d);
    mdMap[key] = SecondaryUtil.removeNulls(atMetaData.toJson())!;
  }

  FakeHttpRequest createRequest(String method, String path) {
    final req = FakeHttpRequest(
        method, Uri.parse('https://alice.atservers.swarm/$path'));
    return req;
  }

  String publicFoo = 'public:foo$alice';
  String publicFooBar = 'public:foo.bar$alice';
  String publicFooBarBaz = 'public:foo.bar.baz$alice';
  String publicIndexHtml = 'public:index.html.foo.bar.baz$alice';
  String publicIndexHtmlBody = '<body><h1>Hello, world!!!</h1></body>';
  String hiddenIndexHtml = 'public:_index.html.foo.bar.baz$alice';
  String hiddenIndexHtmlBody = '<body><h1>Hidden worlds</h1></body>';

  setUp(() async {
    await verbTestsSetUp();
    handler = AtServerHttpRequestHandler(alice, secondaryKeyStore);
    handler.logger.level = 'warning';
    await put(publicFoo);
    await put(publicFooBar);
    await put(publicFooBarBaz);
    await put(publicIndexHtml, value: publicIndexHtmlBody);
    await put(hiddenIndexHtml, value: hiddenIndexHtmlBody);
  });

  tearDown(() async {
    await verbTestsTearDown();
  });

  Future<void> check(
    int expectedStatus,
    String expectedBody,
    String method,
    String uri,
  ) async {
    final FakeHttpRequest request = createRequest(method, uri);
    await (handler.handle(request));
    expect(request.response.statusCode, expectedStatus);
    switch (request.response.statusCode) {
      case HttpStatus.ok:
        break;
      case HttpStatus.notFound:
        expectedBody = '404 Not Found';
        break;
      default:
        expectedBody = '';
    }
    expect(request.response.body, expectedBody);
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
    required String expectedBody,
    required String method,
    required String key,
  }) async {
    String fullKey = handler.getKeyToLookup('public:$key$atSign');

    // WITH public: prefix, WITH atSign suffix
    await check(expectedStatus, expectedBody, method, '/public:$key$atSign');
    await check(expectedStatus, jsonEncode(mdMap[fullKey]), method,
        '/public:$key$atSign?at_rt=meta');

    // WITH public: prefix, WITHOUT atSign suffix
    await check(expectedStatus, expectedBody, method, '/public:$key');
    await check(expectedStatus, jsonEncode(mdMap[fullKey]), method,
        '/public:$key?at_rt=meta');

    // WITHOUT public: prefix, WITH atSign suffix
    await check(expectedStatus, expectedBody, method, '/$key$atSign');
    await check(expectedStatus, jsonEncode(mdMap[fullKey]), method,
        '/$key$atSign?at_rt=meta');

    // WITHOUT public: prefix, WITHOUT atSign suffix
    await check(expectedStatus, expectedBody, method, '/$key');
    await check(
        expectedStatus, jsonEncode(mdMap[fullKey]), method, '/$key?at_rt=meta');
  }

  group('http basic checks status 200', () {
    test('get public key', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: publicFoo,
          method: 'GET',
          key: 'foo');
    });

    test('get public key with namespace', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: publicFooBar,
          method: 'GET',
          key: 'foo.bar');
    });

    test('get public key with namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: publicFooBarBaz,
          method: 'GET',
          key: 'foo.bar.baz');
    });

    test('get public key with many namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: publicIndexHtmlBody,
          method: 'GET',
          key: 'index.html.foo.bar.baz');
    });

    test('get public hidden key with many namespaces', () async {
      await basicChecks(
          expectedStatus: HttpStatus.ok,
          expectedBody: hiddenIndexHtmlBody,
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
          expectedBody: publicIndexHtmlBody,
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
          expectedBody: hiddenIndexHtmlBody,
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
        method: 'GET',
        key: 'nope',
      );
    });
    test('self key', () async {
      await basicChecks(
        expectedStatus: HttpStatus.notFound,
        expectedBody: '404 Not Found',
        method: 'GET',
        key: '$alice:foo.bar$alice',
      );
    });
    test('shared key', () async {
      await basicChecks(
        expectedStatus: HttpStatus.notFound,
        expectedBody: '404 Not Found',
        method: 'GET',
        key: '$bob:foo.bar$alice',
      );
    });
    test('HEAD', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        method: 'HEAD',
        key: publicFooBar,
      );
    });
    test('PUT', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        method: 'PUT',
        key: publicFooBar,
      );
    });
    test('POST', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        method: 'POST',
        key: publicFooBar,
      );
    });
    test('DELETE', () async {
      await basicChecks(
        expectedStatus: HttpStatus.methodNotAllowed,
        expectedBody: '',
        method: 'DELETE',
        key: publicFooBar,
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
        method: 'GET',
        key: b.toString(),
      );
    });
  });
}

class FakeHttpResponse extends Fake implements HttpResponse {
  StringBuffer b = StringBuffer();

  String get body => b.toString();
  bool _isClosed = false;

  @override
  late int statusCode;

  @override
  void write(Object? object) {
    if (_isClosed) {
      throw StateError('FakeHttpResponse is closed');
    }
    b.write(object);
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
