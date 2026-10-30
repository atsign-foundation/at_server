import 'dart:collection';
import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_secondary/src/exception/global_exception_handler.dart';
import 'package:at_secondary/src/utils/logging_util.dart';
import 'package:at_secondary/src/verb/handler/abstract_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/delete_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/local_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/notify_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/proxy_lookup_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_meta_verb_handler.dart';
import 'package:at_secondary/src/verb/handler/update_verb_handler.dart';
import 'package:at_secondary/src/verb/verb_enum.dart';
import 'package:at_server_spec/at_verb_spec.dart';
import 'package:at_server_spec/at_server_spec.dart';

/// An entry of a batch: its id, its command, and the handler that runs it.
typedef _Entry = ({int? id, String command, AbstractVerbHandler handler});

/// Handles `batch:`: checks every entry is a command a batch may carry, then
/// runs them in order, answering each in the batch's response.
class BatchVerbHandler extends AbstractVerbHandler {
  static Batch batch = Batch();
  final VerbHandlerManager verbHandlerManager;

  BatchVerbHandler(super.keyStore, this.verbHandlerManager);

  /// Why a batch is refused whole: the entry at [position], counting from 1,
  /// is not a command a batch may carry.
  static String refusal(int position) =>
      'a batch may carry only lookup, llookup, plookup, notify, update and'
      ' delete; entry $position is not one';

  // Method to verify whether command is accepted or not
  // Input: command
  @override
  bool accept(String command) =>
      command.startsWith('${getName(VerbEnum.batch)}:');

  // Method to return Instance of verb belongs to this VerbHandler
  @override
  Verb getVerb() {
    return batch;
  }

  @override
  HashMap<String, String?> parse(String command) {
    var verbParams = super.parse(command);
    return verbParams;
  }

  // Method which will process update Verb
  // This will process given verb and write response to response object
  // Input : Response, verbParams, AtConnection
  @override
  Future<void> processVerb(
      Response response,
      HashMap<String, String?> verbParams,
      InboundConnection atConnection) async {
    var batchCommand = verbParams['json']!;
    var batchJson = jsonDecode(batchCommand);
    if (batchJson is! List) {
      throw InvalidSyntaxException('a batch is a list of entries');
    }
    final List<_Entry> entries = [];
    for (final (int index, Object? value) in batchJson.indexed) {
      final _Entry? entry = _carried(value);
      if (entry == null) {
        logger.warning('Refusing a batch of ${batchJson.length} entries on'
            ' session ${atConnection.metaData.sessionID}: entry ${index + 1}'
            ' is not a command a batch may carry');
        throw InvalidSyntaxException(refusal(index + 1));
      }
      entries.add(entry);
    }
    var batchResponses = <BatchResponse>[];
    for (final _Entry entry in entries) {
      try {
        var response =
            await entry.handler.processInternal(entry.command, atConnection);
        var batchResponse = BatchResponse(entry.id, response);
        batchResponses.add(batchResponse);
      } on Exception catch (e) {
        logger.info('Entry ${entry.id} of a batch on session'
            ' ${atConnection.metaData.sessionID}: ${sanitiseForLogging('$e')}');
        batchResponses.add(BatchResponse(entry.id, _failed(e)));
      } on Error catch (e, st) {
        logger.severe('${sanitiseForLogging('$e')} running entry ${entry.id}'
            ' of a batch on session ${atConnection.metaData.sessionID}\n$st');
        batchResponses
            .add(BatchResponse(entry.id, _failed(InternalServerError('$e'))));
      }
    }
    response.data = jsonEncode(batchResponses);
  }

  /// The answer to an entry whose command threw [e]: its error code, or
  /// AT0011 for an exception that has none.
  Response _failed(Exception e) {
    final GlobalExceptionHandler errors = GlobalExceptionHandler.getInstance();
    final String code = errors.getErrorCode(e) ?? 'AT0011';
    return Response()
      ..errorCode = code
      ..errorMessage = errors.getErrorDescription(code);
  }

  /// [value] as an entry, when it is one whose command a batch may carry,
  /// else null.
  _Entry? _carried(Object? value) {
    if (value is! Map) {
      return null;
    }
    final Object? id = value['id'];
    final Object? command = value['command'];
    if ((id != null && id is! int) || command is! String) {
      return null;
    }
    final VerbHandler? handler = verbHandlerManager.getVerbHandler(command);
    final bool carried = handler is LookupVerbHandler ||
        handler is LocalLookupVerbHandler ||
        handler is ProxyLookupVerbHandler ||
        handler is NotifyVerbHandler ||
        handler is UpdateVerbHandler ||
        handler is UpdateMetaVerbHandler ||
        handler is DeleteVerbHandler;
    return carried
        ? (
            id: id as int?,
            command: command,
            handler: handler as AbstractVerbHandler
          )
        : null;
  }
}
