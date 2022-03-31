import 'dart:io';

import 'package:at_secondary/src/connection/inbound/inbound_connection_metadata.dart';
import 'package:at_server_spec/at_server_spec.dart';
import 'package:at_utils/at_logger.dart';

/// A dummy implementation of [InboundConnection] class which returns a dummy inbound connection.
class DummyInboundConnection implements InboundConnection {
  static var logger = AtSignLogger('DummyInboundConnection');

  static final Map<String, DummyInboundConnection> _instances = {};
  factory DummyInboundConnection.getInstance(String purpose) {
    if (_instances[purpose] != null) {
      // Found an existing instance ...
      DummyInboundConnection existingInstance = _instances[purpose]!;
      // ... but wait! if its metadata says it's closed, we need to ditch it and create a new one
      // otherwise, bad things happen. Long story. See https://github.com/atsign-foundation/at_server/pull/615
      if (existingInstance.metadata.isClosed) {
        logger.info('Booting existing instance for $purpose as it isClosed; creating new one');
        _instances.remove(existingInstance);

        DummyInboundConnection instance = DummyInboundConnection._(purpose);
        _instances[purpose] = instance;
        return instance;
      } else {
        logger.info('Returning existing instance for $purpose');
        return existingInstance;
      }
    } else {
      // No existing instance. Let's mint a new one
      logger.info('Creating new instance for $purpose');
      DummyInboundConnection instance = DummyInboundConnection._(purpose);
      _instances[purpose] = instance;
      return instance;
    }
  }

  late InboundConnectionMetadata metadata;

  DummyInboundConnection._(String purpose) {
    var metadata = InboundConnectionMetadata();
    metadata.sessionID = '$purpose-dummy-inbound-connection';
  }

  @override
  void acceptRequests(Function(String p1, InboundConnection p2) callback,
      Function(List<int>, InboundConnection) streamCallback) {}

  @override
  Future<void> close() async {}

  @override
  bool equals(InboundConnection other) {
    return identical(this, other);
  }

  @override
  AtConnectionMetaData getMetaData() {
    metadata.fromAtSign = null;
    return metadata;
  }

  @override
  Socket getSocket() {
    throw ('not implemented');
  }

  @override
  bool isInValid() {
    return metadata.isClosed;
  }

  @override
  void write(String data) {}

  @override
  bool? isMonitor;

  @override
  String? initiatedBy;

  bool isStream = false;

  @override
  Socket? receiverSocket;
}
