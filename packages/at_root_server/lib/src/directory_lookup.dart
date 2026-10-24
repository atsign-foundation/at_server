import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_root_server/at_persistence_root_server.dart';

/// Looks up the record the atDirectory holds for [atSign], given without its
/// leading @: its atServer's host:port, or null when it holds none.
typedef DirectoryLookup = Future<String?> Function(String atSign);

final RedisKeystore _redisKeystore = RedisKeystore();

/// The atDirectory's records, read from Redis.
Future<String?> redisDirectoryLookup(String atSign) =>
    _redisKeystore.get(atSign);

/// The atDirectory's key for [name], an atSign with or without its leading
/// @: its canonical form without the @, or null when [name] is not an atSign.
String? directoryKeyOf(String name) {
  try {
    return (name.startsWith('@') ? name : '@$name').toAtsign().substring(1);
  } on InvalidAtSignException {
    return null;
  }
}
