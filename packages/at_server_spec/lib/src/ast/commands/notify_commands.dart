part of '../command.dart';

/// `notify[:id:<id>][:(update|delete)][:messageType:<key|text>][:priority:<p>][:strategy:<all|latest>][:latestN:<n>][:notifier:<n>][:ttln:<ms>][:eAtn:<ISO8601>][:eph]<metadataFragment>:(public|@<forAtSign>):<atKey>[@<atSign>][:<value>]`
///
/// Source: `VerbSyntax.notify` (at_commons `syntax.dart:117-132`).
final class NotifyCommand extends Command {
  final String? id;
  final NotifyOperation? operation;
  final MessageType? messageType;
  final Priority? priority;
  final NotifyStrategy? strategy;
  final int? latestN;
  final String? notifier;

  /// `ttln` — notification time-to-live in ms.
  final int? ttln;

  /// `eAtn` — the notification's own expiry.
  final DateTime? notificationExpiresAt;

  /// `:eph` — ephemeral notification.
  final bool ephemeral;

  final MetadataFragment metadata;

  /// Required for this verb, unlike `update`/`delete`/`llookup`.
  final KeyScope scope;

  final String atKey;
  final String? atSign;
  final String? value;

  const NotifyCommand({
    required this.scope,
    required this.atKey,
    this.atSign,
    this.value,
    this.id,
    this.operation,
    this.messageType,
    this.priority,
    this.strategy,
    this.latestN,
    this.notifier,
    this.ttln,
    this.notificationExpiresAt,
    this.ephemeral = false,
    this.metadata = const MetadataFragment(),
  });

  @override
  Map<String, Object?> get _fields => {
        'id': id,
        'operation': operation,
        'messageType': messageType,
        'priority': priority,
        'strategy': strategy,
        'latestN': latestN,
        'notifier': notifier,
        'ttln': ttln,
        'notificationExpiresAt': notificationExpiresAt,
        'ephemeral': ephemeral,
        'metadata': metadata,
        'scope': scope,
        'atKey': atKey,
        'atSign': atSign,
        'value': value,
      };
}

/// `notify:all:[(update|delete):][messageType:<key|text>:][ttl:<n>:][ttb:<n>:][ttr:<n>:][ccd:<bool>:]<forAtSign-list>:<atKey>[@<atSign>][:<value>]`
///
/// Source: `VerbSyntax.notifyAll` (at_commons `syntax.dart:137-145`). Uses
/// its own numeric/bool tags, not [MetadataFragment]; the wire `ccd` also
/// accepts `false+` (e.g. `falsee`), which still means `false`.
final class NotifyAllCommand extends Command {
  final NotifyOperation? operation;
  final MessageType? messageType;
  final int? ttl;
  final int? ttb;
  final int? ttr;
  final bool? ccd;

  /// Comma-separated recipients, in wire order, as captured (the grammar
  /// neither requires nor strips an `@` here). May be empty.
  final List<String> forAtSigns;

  final String atKey;
  final String? atSign;
  final String? value;

  NotifyAllCommand({
    required List<String> forAtSigns,
    required this.atKey,
    this.atSign,
    this.value,
    this.operation,
    this.messageType,
    this.ttl,
    this.ttb,
    this.ttr,
    this.ccd,
  }) : forAtSigns = List.unmodifiable(forAtSigns);

  @override
  Map<String, Object?> get _fields => {
        'operation': operation,
        'messageType': messageType,
        'ttl': ttl,
        'ttb': ttb,
        'ttr': ttr,
        'ccd': ccd,
        'forAtSigns': forAtSigns,
        'atKey': atKey,
        'atSign': atSign,
        'value': value,
      };
}

/// `notify:list[:<fromDate>][:<toDate>][:<regex>]`
///
/// Source: `VerbSyntax.notifyList` (at_commons `syntax.dart:133-134`). The
/// dates match the loose pattern `\d{4}-[01]?\d?-[0123]?\d?` (e.g. `2026-1-`
/// is accepted), so they're kept as raw strings rather than [DateTime]s.
final class NotifyListCommand extends Command {
  final String? fromDate;
  final String? toDate;
  final String? regex;

  const NotifyListCommand({this.fromDate, this.toDate, this.regex});

  @override
  Map<String, Object?> get _fields =>
      {'fromDate': fromDate, 'toDate': toDate, 'regex': regex};
}

/// `notify:status:<notificationId>`
///
/// Source: `VerbSyntax.notifyStatus` (at_commons `syntax.dart:135`).
final class NotifyStatusCommand extends Command {
  final String notificationId;

  const NotifyStatusCommand({required this.notificationId});

  @override
  Map<String, Object?> get _fields => {'notificationId': notificationId};
}

/// `notify:fetch:<notificationId>`
///
/// Source: `VerbSyntax.notifyFetch` (at_commons `syntax.dart:136`).
final class NotifyFetchCommand extends Command {
  final String notificationId;

  const NotifyFetchCommand({required this.notificationId});

  @override
  Map<String, Object?> get _fields => {'notificationId': notificationId};
}

/// `notify:remove:<id>`
///
/// Source: `VerbSyntax.notifyRemove` (at_commons `syntax.dart:156`).
final class NotifyRemoveCommand extends Command {
  final String id;

  const NotifyRemoveCommand({required this.id});

  @override
  Map<String, Object?> get _fields => {'id': id};
}

/// `monitor[:strict][:selfNotifications][:multiplexed][:<epochMillis>][ <regex>]`
///
/// Source: `VerbSyntax.monitor` (at_commons `syntax.dart:107-113`).
final class MonitorCommand extends Command {
  final bool strict;
  final bool selfNotifications;
  final bool multiplexed;
  final int? epochMillis;
  final String? regex;

  const MonitorCommand({
    this.strict = false,
    this.selfNotifications = false,
    this.multiplexed = false,
    this.epochMillis,
    this.regex,
  });

  @override
  Map<String, Object?> get _fields => {
        'strict': strict,
        'selfNotifications': selfNotifications,
        'multiplexed': multiplexed,
        'epochMillis': epochMillis,
        'regex': regex,
      };
}

/// `stream:[<operation>][@<receiver>][ namespace:<ns>][ startByte:<n>][ <streamId>][ <fileName> ][<length>]`
///
/// Source: `VerbSyntax.stream` (at_commons `syntax.dart:114-115`). The regex
/// is loose and ambiguous; fields mirror its named groups one-to-one.
final class StreamCommand extends Command {
  final StreamOperation? operation;
  final String? receiver;
  final String? namespace;
  final int? startByte;
  final String? streamId;
  final String? fileName;
  final int? length;

  const StreamCommand({
    this.operation,
    this.receiver,
    this.namespace,
    this.startByte,
    this.streamId,
    this.fileName,
    this.length,
  });

  @override
  Map<String, Object?> get _fields => {
        'operation': operation,
        'receiver': receiver,
        'namespace': namespace,
        'startByte': startByte,
        'streamId': streamId,
        'fileName': fileName,
        'length': length,
      };
}
