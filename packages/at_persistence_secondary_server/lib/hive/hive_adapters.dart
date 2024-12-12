import 'package:hive_ce/hive.dart';
import 'package:at_persistence_secondary_server/src/log/accesslog/access_entry.dart';
import 'package:at_persistence_secondary_server/src/log/commitlog/commit_entry.dart';
import 'package:at_persistence_secondary_server/src/model/at_data.dart';
import 'package:at_persistence_secondary_server/src/model/at_meta_data.dart';
import 'package:at_persistence_secondary_server/src/notification/at_notification.dart';

//part 'hive_adapters.g.dart';

@GenerateAdapters([
  AdapterSpec<AtData>(),
  AdapterSpec<AtMetaData>(),
  AdapterSpec<CommitEntry>(),
  AdapterSpec<CommitOp>(),
  AdapterSpec<AccessLogEntry>(),
  AdapterSpec<NotificationStatus>(),
  AdapterSpec<AtNotification>(),
  AdapterSpec<NotificationType>(),
  AdapterSpec<OperationType>(),
  AdapterSpec<NotificationPriority>(),
  AdapterSpec<MessageType>(),
])
// This is for code generation
// ignore: unused_element
void _() {}
