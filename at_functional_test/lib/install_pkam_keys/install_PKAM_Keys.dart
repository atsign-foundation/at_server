import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;
import 'package:at_lookup/at_lookup.dart';

void main(List<String> arguments) async {
  at_demo_data.allAtsigns.forEach((atSign) {
    if (atSign != 'anonymous') {
      lookItUp(atSign);
    }
  });
}

void lookItUp(String atSign) async {
  try {
    print(atSign);
    var _atLookup = AtLookupImpl(atSign, 'vip.ve.atsign.zone', 64);
    //print(at_demo_data.cramKeyMap[atSign]);
    await _atLookup.authenticate_cram(at_demo_data.cramKeyMap[atSign]);
    var command = 'update:public:PKAMINSTALLED' + atSign + ' YES\n';
    //print(command);
    await _atLookup.executeCommand(command);

    command = 'update:privatekey:at_pkam_publickey ' +
        at_demo_data.pkamPublicKeyMap[atSign]! +
        '\n';
    print(command);
    await _atLookup.executeCommand(command);

    command = 'update:public:publickey$atSign ' +
        at_demo_data.encryptionPublicKeyMap[atSign]! +
        '\n';
    print(command);
    await _atLookup.executeCommand(command);

    var installed = await _atLookup.llookup('public:pkaminstalled');
    ;
    print('PKAM Installed for $atSign : ' +
        installed.toString().replaceFirst('data:', ''));
    await _atLookup.close();
  } on Exception catch (e) {
    print('error while setting keys for $atSign exception: ${e.toString()}');
  }
}
