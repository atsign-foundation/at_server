import 'dart:convert';
import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:at_persistence_secondary_server/src/keystore/hive_keystore_helper.dart';
import 'package:at_persistence_secondary_server/src/utils/object_util.dart';
import 'package:at_persistence_spec/at_persistence_spec.dart';
import 'package:at_utils/at_logger.dart';
import 'package:elastic_client/elastic_client.dart';
import 'package:utf7/utf7.dart';
import 'package:uuid/uuid.dart';

class ElasticKeyStore implements IndexableKeyStore<String, AtData, AtMetaData>, SecondaryKeyStore<String, AtData, AtMetaData> {
  final logger = AtSignLogger('ElasticKeyStore');
  var _atSign;

  static Client client;

  var keyStoreHelper = HiveKeyStoreHelper.getInstance();
  var _commitLog;

  static final ElasticKeyStore _instance = ElasticKeyStore._internal();

  factory ElasticKeyStore() {
    return _instance;
  }

  ElasticKeyStore._internal() {
    try {
      var transport = HttpTransport(url: 'http://localhost:9200/');
      client = Client(transport);
    } on Exception catch (e) {
      logger.severe('AtPersistence.init exception: ' + e.toString());
      throw DataStoreException(
          'Exception initializing secondary keystore manager: ${e.toString()}');
    }
  }

  set commitLog(value) {
    _commitLog = value;
  }

  @override
  Future create(String key, AtData value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
    var result;
    var commitOp;
    var elastic_key = keyStoreHelper.prepareKey(key);
    var elastic_data = keyStoreHelper.prepareDataForCreate(value,
        ttl: time_to_live,
        ttb: time_to_born,
        ttr: time_to_refresh,
        isCascade: isCascade,
        isBinary: isBinary,
        isEncrypted: isEncrypted,
        dataSignature: dataSignature);
    // Default commitOp to Update.
    commitOp = CommitOp.UPDATE;

    // Setting metadata defined in values
    if (value != null && value.metaData != null) {
      time_to_live ??= value.metaData.ttl;
      time_to_born ??= value.metaData.ttb;
      time_to_refresh ??= value.metaData.ttr;
      isCascade ??= value.metaData.isCascade;
      isBinary ??= value.metaData.isBinary;
      isEncrypted ??= value.metaData.isEncrypted;
      dataSignature ??= value.metaData.dataSignature;
    }

    // If metadata is set, set commitOp to Update all
    if (ObjectsUtil.isAnyNotNull(
        a1: time_to_live,
        a2: time_to_born,
        a3: time_to_refresh,
        a4: isCascade,
        a5: isBinary,
        a6: isEncrypted)) {
      commitOp = CommitOp.UPDATE_ALL;
    }

    try {
      var value =
          (elastic_data != null) ? json.encode(elastic_data.toJson()) : null;


      await client.updateDoc(
        index: 'tutorial',
        type: 'helloworld',
        id: elastic_key,
        doc: {"data": value},
      );
      await client.flushIndex(index: 'tutorial');
      result = await _commitLog.commit(elastic_key, commitOp);
      return result;
    } on Exception catch (exception) {
      logger.severe('ElasticKeystore create exception: $exception');
      throw DataStoreException('exception in create: ${exception.toString()}');
    }
  }


  @override
  Future<AtData> get(String key) async {
    var value = AtData();
    try {
      var elastic_key = keyStoreHelper.prepareKey(key);
      // var conditions = [];
      // conditions.add(Query.match('id', elastic_key));
      // var query = Query.bool(should: conditions);
      var query = Query.match('_id', elastic_key);
      var esResult = await client
          .search(index: 'tutorial', type: 'helloworld', query: query);
      logger.info('es result : ${esResult.toMap()}');
      var result = esResult.toMap()['doc'];
      // var result = await persistenceManager.client
      //     .search('my_index', 'my_type', query: Query.term('id', [elastic_key]) );
      if (result != null) {
        value = value.fromJson(json.decode(result));
      }
    } on Exception catch (exception) {
      logger.severe('ElasticKeystore get exception: $exception');
      throw DataStoreException('exception in get: ${exception.toString()}');
    }
    return value;
  }

  @override
  Future<AtMetaData> getMeta(String key) {
    // TODO: implement getMeta
    throw UnimplementedError();
  }

  @override
  Future put(String key, AtData value,
      {int time_to_live,
      int time_to_born,
      int time_to_refresh,
      bool isCascade,
      bool isBinary,
      bool isEncrypted,
      String dataSignature}) async {
    var result;
    // Default the commit op to just the value update
    var commitOp = CommitOp.UPDATE;
    // Verifies if any of the args are not null
    var isMetadataNotNull = ObjectsUtil.isAnyNotNull(
        a1: time_to_live,
        a2: time_to_born,
        a3: time_to_refresh,
        a4: isCascade,
        a5: isBinary,
        a6: isEncrypted);
    if (isMetadataNotNull) {
      // Set commit op to UPDATE_META
      commitOp = CommitOp.UPDATE_META;
    }
    if (value != null) {
      commitOp = CommitOp.UPDATE_ALL;
    }
    try {
      assert(key != null);
      var existingData = await get(key);
      if (existingData == null) {
        result = await create(key, value,
            time_to_live: time_to_live,
            time_to_born: time_to_born,
            time_to_refresh: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature);
      } else {
        var elastic_key = keyStoreHelper.prepareKey(key);
        var elastic_value = keyStoreHelper.prepareDataForUpdate(
            existingData, value,
            ttl: time_to_live,
            ttb: time_to_born,
            ttr: time_to_refresh,
            isCascade: isCascade,
            isBinary: isBinary,
            isEncrypted: isEncrypted,
            dataSignature: dataSignature);
        logger.finest('elastic key:${elastic_key}');
        logger.finest('elastic value:${elastic_value}');
        // await persistenceManager.box?.put(elastic_key, elastic_value);
        // result = await _commitLog.commit(elastic_key, commitOp);
        var elastic_value_json = (elastic_value != null)
            ? json.encode(elastic_value.toJson())
            : null;
        await client.updateDoc(
          index: 'tutorial',
          type: 'helloworld',
          id: elastic_key,
          doc: Map<String, dynamic>.from(elastic_value.toJson()),
        );
        result = await _commitLog.commit(elastic_key, commitOp);
      }
    } on DataStoreException {
      rethrow;
    } on Exception catch (exception) {
      logger.severe('ElasticKeystore put exception: $exception');
      throw DataStoreException('exception in put: ${exception.toString()}');
    }
    return result;
  }

  @override
  Future putAll(String key, AtData value, AtMetaData metadata) async {
    var result;
    var elastic_key = keyStoreHelper.prepareKey(key);
    value.metaData = AtMetadataBuilder(newAtMetaData: metadata).build();
    // Updating the version of the metadata.
    (metadata.version != null) ? metadata.version += 1 : metadata.version = 0;
    await client.updateDoc(
      index: 'tutorial',
      type: 'helloworld',
      id: elastic_key,
      doc: {"data": value},
    );
    result = await _commitLog.commit(elastic_key, CommitOp.UPDATE_ALL);
    return result;
  }

  @override
  Future putMeta(String key, AtMetaData metadata) async {
    var elastic_key = keyStoreHelper.prepareKey(key);
    var existingData = await get(key);
    var newData = existingData ?? AtData();
    newData.metaData = AtMetadataBuilder(
            newAtMetaData: metadata, existingMetaData: newData.metaData)
        .build();
    // Updating the version of the metadata.
    (newData.metaData.version != null)
        ? newData.metaData.version += 1
        : newData.metaData.version = 0;
    await client.updateDoc(
        index: 'tutorial', type: 'helloworld', id: elastic_key, doc: {"data": newData});
    var result = await _commitLog.commit(elastic_key, CommitOp.UPDATE_META);
    return result;
  }

  @override
  Future remove(String key) async {
    var result;
    try {
      assert(key != null);
      await client.deleteDoc(index: 'tutorila', id: key);
      result = await _commitLog.commit(key, CommitOp.DELETE);
      return result;
    } on Exception catch (exception) {
      logger.severe('ElasticKeystore delete exception: $exception');
      throw DataStoreException('exception in remove: ${exception.toString()}');
    }
  }

  @override
  void unindex(String id, {String index}) async {
    index ??= 'my_index';
    await client.deleteDoc(index: index, id: id);
  }

  @override
  Future<String> index(String data, {String id, String index}) async {
    index ??= 'my_index';

    id ??= Uuid().v1();

    var success = await client.updateDoc(
      index: index,
      type: 'my_type',
      id: id,
      doc: json.decode(data),
    );

    await client.flushIndex(index: index);
    return success ? id : null;
  }

  @override
  Future<List<String>> search(
      List<String> keywords,
      {String index, int fuzziness = 0,
        bool contains = false}) async {

    index ??= 'my_index';

    var result = <String>[];

    var searchQuery = '${keywords[0]}';
    for (var i = 1; i < keywords.length; i++) {
      searchQuery += '  ${keywords[i]}';
    }

    List<Hit> hits;

    if (fuzziness > 0) {
      hits = (await client.search(
        index: index,
        type: 'my_type',
        query: {
          'simple_query_string': {
            'query': searchQuery + '~$fuzziness',
            'fields': ['*'],
            'fuzzy_max_expansions': fuzziness,
            'fuzzy_transpositions': true
          }
        }
      )).hits;
    }
    else if (contains) {

      searchQuery = '*${keywords[0]}*';
      for (var i = 1; i < keywords.length; i++) {
        searchQuery += ' *${keywords[i]}*';
      }

      hits = (await client.search(
        index: index,
        type: 'my_type',
        query: {
          'query_string': {
            'query': searchQuery,
            'fields': ['*']
          }
        }
      )).hits;
    }
    else {
      hits = (await client.search(
          index: index,
          type: 'my_type',
          query: {
            'simple_query_string': {
              'query': searchQuery,
              'fields': ['*']
            }
          }
      )).hits;
    }

    for (var hit in hits) {
      result.add(hit.doc.toString());
    }

    return result;
  }

  @override
  bool deleteExpiredKeys() {
    // TODO: implement deleteExpiredKeys
    throw UnimplementedError();
  }

  @override
  List<String> getExpiredKeys() {
    // TODO: implement getExpiredKeys
    throw UnimplementedError();
  }

  @override
  List<String> getKeys({String regex}) {
    // TODO: implement getKeys
    throw UnimplementedError();
  }
}
