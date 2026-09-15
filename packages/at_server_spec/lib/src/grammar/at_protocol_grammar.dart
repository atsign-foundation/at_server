import 'grammars/complex_grammars.dart';
import 'grammars/delete_grammar.dart';
import 'grammars/from_grammar.dart';
import 'grammars/llookup_grammar.dart';
import 'grammars/lookup_grammar.dart';
import 'grammars/notify_grammar.dart';
import 'grammars/pkam_grammar.dart';
import 'grammars/plookup_grammar.dart';
import 'grammars/simple_grammars.dart';
import 'grammars/update_grammar.dart';
import 'grammars/update_meta_grammar.dart';
import 'verb_grammar.dart';

/// The canonical registry of verb grammars. Keyed by the verb name returned by
/// `Verb.name()` so the server can look up a grammar for the handler it already
/// selected. Grammars are added here as they are ported from `VerbSyntax`.
final Map<String, VerbGrammar> verbGrammars = {
  'from': fromGrammar,
  'pkam': pkamGrammar,
  'llookup': llookupGrammar,
  'lookup': lookupGrammar,
  'plookup': plookupGrammar,
  'delete': deleteGrammar,
  'update': updateGrammar,
  'update:meta': updateMetaGrammar,
  'notify': notifyGrammar,
  'pol': polGrammar,
  'noop': noopGrammar,
  'cram': cramGrammar,
  'batch': batchGrammar,
  'info': infoGrammar,
  'sync': syncGrammar,
  'sync:from': syncFromGrammar,
  'monitor': monitorGrammar,
  'notify:status': notifyStatusGrammar,
  'notify:fetch': notifyFetchGrammar,
  'notify:remove': notifyRemoveGrammar,
  'notify:list': notifyListGrammar,
  'scan': scanGrammar,
  'otp': otpGrammar,
  'stats': statsGrammar,
  'enroll': enrollGrammar,
  'config': configGrammar,
  'keys': keysGrammar,
  'notify:all': notifyAllGrammar,
  // NOTE: `stream` is intentionally not yet ported — its regex is extremely
  // loose/ambiguous. Until ported, parseAs('stream', ...) returns null and the
  // server falls back to the legacy regex.
};
