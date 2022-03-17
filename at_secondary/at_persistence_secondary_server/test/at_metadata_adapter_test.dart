import 'package:at_commons/at_commons.dart';
import 'package:at_persistence_secondary_server/at_persistence_secondary_server.dart';
import 'package:hive/hive.dart';
import 'package:test/test.dart';

void main() async {
  test('at_meta_data adaptertest', () async {
    final metaData = Metadata()
      ..ttl = 1000
      ..ccd = true
      ..pubKeyCS = 'xyz'
      ..sharedKeyEnc = 'abc'
      ..isBinary = false;
    final atMetaData = AtMetadataAdapter(metaData)!;
    expect(atMetaData.ttl, 1000);
    expect(atMetaData.isCascade, true);
    expect(atMetaData.pubKeyCS, 'xyz');
    expect(atMetaData.sharedKeyEnc, 'abc');
    expect(atMetaData.isBinary, false);
  });
}
