import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';

/// The most characters a notification's key may have where its recipient
/// holds it.
const int maxNotificationKeyLength = 255;

/// Whether the recipient of a notification caches it: it has a ttr, or it
/// is a delete.
bool cachedByRecipient({required bool hasTtr, required bool isDelete}) =>
    hasTtr || isDelete;

/// Whether the recipient of [n] caches it.
bool notificationCachedByRecipient(AtNotification n) => cachedByRecipient(
    hasTtr: n.atMetadata?.ttr != null,
    isDelete: n.opType == OperationType.delete);

/// How many characters [key], a notification's key, has where its recipient
/// holds it: with the `cached:` prefix when the recipient caches it.
int notificationKeyLength(String key, {required bool cached}) =>
    cached ? '${AtConstants.cached}:$key'.length : key.length;

/// Throws [InvalidAtKeyException] when [key] would be longer than
/// [maxNotificationKeyLength] where its recipient holds it.
void refuseOverlongNotificationKey(String key, {required bool cached}) {
  final int length = notificationKeyLength(key, cached: cached);
  if (length > maxNotificationKeyLength) {
    throw InvalidAtKeyException('notification key length $length is greater'
        ' than $maxNotificationKeyLength chars');
  }
}
