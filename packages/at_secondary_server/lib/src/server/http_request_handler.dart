import 'dart:io';

import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_secondary/src/utils/secondary_util.dart';
import 'package:at_utils/at_logger.dart';

const String atRequestType = 'at_rt';

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

      logger.info(
          'Handling Http Request: ${request.method} path: ${request.uri.path} params: ${request.uri.queryParameters}');
      if (request.method.toUpperCase() != 'GET') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      } else {
        String decodedPath = Uri.decodeComponent(request.uri.path);
        logger.finer('Decoded path $decodedPath');

        String lookupKey = getKeyToLookup(decodedPath);
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
        logger.info(
            'request type: ${request.uri.queryParameters[atRequestType]}');
        request.response.statusCode = HttpStatus.ok;
        request.response.write(SecondaryUtil.prepareResponseData(
          request.uri.queryParameters[atRequestType],
          atData,
        ));
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
}
