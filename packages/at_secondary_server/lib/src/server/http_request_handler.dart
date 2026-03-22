import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';
import 'package:mime/mime.dart' as mime;
import 'package:at_base2e15/at_base2e15.dart';

const String paramNameAtRequestType = 'at_rt';
const String paramNameContentType = 'at_ct';

class AtServerHttpRequestHandler {
  final String currentAtSign;
  final SecondaryKeyStore<String, AtData?, AtMetaData?> secondaryKeyStore;
  final logger = AtSignLogger('Http Request Handler');

  AtServerHttpRequestHandler(this.currentAtSign, this.secondaryKeyStore);

  Future<void> handle(HttpRequest request) async {
    try {
      // Reject malformed (too long to be keyStore keys) requests
      if (request.uri.toString().length > 1000) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }

      if (request.method.toUpperCase() != 'GET') {
        logger.info('Ignoring ${request.method}'
            ' ${Uri.decodeComponent(request.uri.path)}');
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      } else {
        final String decodedPath = Uri.decodeComponent(request.uri.path);
        logger.info('Path: $decodedPath'
            ' params: ${request.uri.queryParameters}');

        final String lookupKey = getKeyToLookup(decodedPath);
        logger.info('Key to look up: $lookupKey');

        AtData? atData;
        try {
          atData = (await secondaryKeyStore.get(lookupKey))!;
        } catch (error) {
          request.response.statusCode = HttpStatus.notFound;
          request.response.write('404 Not Found');
          await request.response.close();
          return;
        }

        dynamic responseContent = getResponseContent(
          atData: atData,
          queryParams: request.uri.queryParameters,
        );

        ContentType? responseContentType;
        if (responseContent != null) {
          responseContentType = getResponseContentType(
            isBinary: atData.metaData?.isBinary ?? false,
            queryParams: request.uri.queryParameters,
            keyStoreKey: lookupKey,
          );
        }
        if (responseContentType != null) {
          logger.info('Setting response content-type to $responseContentType');
          request.response.headers.contentType = responseContentType;
        }

        request.response.statusCode = HttpStatus.ok;

        if (responseContent != null) {
          if (responseContent is List<int>) {
            request.response.add(responseContent);
          } else {
            request.response.write(responseContent);
          }
        }

        await request.response.close();
      }
    } catch (e, st) {
      logger.warning('Exception $e handling http request $request');
      logger.warning(st);
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  String getKeyToLookup(String decodedPath) {
    if (decodedPath.contains('?')) {
      decodedPath = decodedPath.substring(0, decodedPath.indexOf('?'));
    }
    while (decodedPath.startsWith('/')) {
      decodedPath = decodedPath.substring(1);
    }
    // For interoperability across access via proxy and direct access,
    // we'd like to use the same URL in both cases
    // i.e. both this URL
    // https://proxy0001.atsign.org/@garycasey/gary/demo/blog/index.html
    // and this one
    // https://85d0d210-2841-59bf-a0c4-3a9a63dd42eb.canary.atsign.zone:11823/@garycasey/gary/demo/blog/index.html
    // should both work.
    if (decodedPath.startsWith('$currentAtSign/')) {
      decodedPath = decodedPath.replaceFirst('$currentAtSign/', '');
    }
    if (decodedPath.startsWith('public:')) {
      decodedPath = decodedPath.replaceFirst('public:', '');
    }
    if (decodedPath.endsWith(currentAtSign)) {
      decodedPath =
          decodedPath.substring(0, decodedPath.length - currentAtSign.length);
    }
    logger.finer('un-prefixed un-suffixed path $decodedPath');
    List<String> pathParts = decodedPath.split('/');
    StringBuffer sb = StringBuffer();
    for (String part in pathParts.reversed) {
      if (part.isEmpty) {
        continue;
      }
      if (sb.isNotEmpty) {
        sb.write('.');
      }
      sb.write(part);
    }
    String lookupKey = sb.toString();
    logger.finer('un-prefixed un-suffixed key to look up: $lookupKey');

    if (!lookupKey.startsWith('public:')) {
      lookupKey = 'public:$lookupKey';
    }
    if (!lookupKey.endsWith(currentAtSign)) {
      lookupKey = '$lookupKey$currentAtSign';
    }

    return lookupKey;
  }

  ContentType? getResponseContentType({
    required bool isBinary,
    required Map<String, String> queryParams,
    required String keyStoreKey,
  }) {
    if (queryParams[paramNameAtRequestType] == 'meta') {
      return ContentType.parse('application/json; charset=utf-8');
    }
    String? inferredMimeType =
        mime.lookupMimeType(getPseudoWebPath(keyStoreKey));
    if (isBinary) {
      String mimeType = queryParams[paramNameContentType] ??
          inferredMimeType ??
          'application/octet-stream';
      final cts = '$mimeType; charset=utf-8';
      final ct = ContentType.parse(cts);
      logger.finer('Got content-type $ct from $cts');
      return ct;
    } else {
      String mimeType =
          queryParams[paramNameContentType] ?? inferredMimeType ?? 'text/plain';
      final cts = '$mimeType; charset=utf-8';
      final ct = ContentType.parse(cts);
      logger.finer('Got content-type $ct from $cts');
      return ct;
    }
  }

  dynamic getResponseContent({
    required AtData atData,
    required Map<String, String> queryParams,
  }) {
    if (atData.data == null) {
      return null;
    }

    if (atData.metaData?.isBinary ?? false) {
      if (queryParams[paramNameAtRequestType] == 'meta') {
        return SecondaryUtil.prepareResponseData(
          queryParams[paramNameAtRequestType],
          atData,
        );
      } else {
        logger.finer('2e15-encoded data length: ${atData.data!.length}');
        // decode to Uint8list
        final bytes = Base2e15.decode(atData.data!);
        logger.finer('decoded data length: ${bytes.length}');
        return bytes;
      }
    } else {
      return SecondaryUtil.prepareResponseData(
        queryParams[paramNameAtRequestType],
        atData,
      );
    }
  }

  String getPseudoWebPath(String keyStoreKey) {
    if (keyStoreKey.startsWith('public:')) {
      keyStoreKey = keyStoreKey.replaceFirst('public:', '');
    }
    if (keyStoreKey.endsWith(currentAtSign)) {
      keyStoreKey =
          keyStoreKey.substring(0, keyStoreKey.length - currentAtSign.length);
    }

    // index.html.foo.bar.baz
    // will become baz/bar/foo/index.html
    final List<String> parts = keyStoreKey.split('.');
    switch (parts.length) {
      case 0:
        return '';
      case 1: // index
        return parts[0];
      case 2: // index.html
        return '${parts[0]}.${parts[1]}';
      default: // index.html.foo.bar.baz => baz/bar/foo/index.html
        StringBuffer sb = StringBuffer(parts.last);
        for (int i = parts.length - 2; i > 1; i--) {
          sb.write('/${parts[i]}');
        }
        sb.write('/${parts[0]}.${parts[1]}');
        return sb.toString();
    }
  }
}
