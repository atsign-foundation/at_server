import 'package:at_demo_data/at_demo_data.dart' as at_demo_data;
import 'package:at_lookup/at_lookup.dart';

void main(List<String> arguments) async {
  await Future.forEach(at_demo_data.allAtsigns, (String atSign) async {
    if (atSign != 'anonymous') {
      await cramAuthAndUpdateKeys(atSign);
    }
  });
  await Future.forEach(at_demo_data.apkamAtsigns, (String atSign) async {
    await cramAuth(atSign);
  });
}

Future<void> cramAuth(String atSign) async {
  try {
    var _atLookup = AtLookupImpl(atSign, 'vip.ve.atsign.zone', 64);
    var isCramAuthSuccessful =
        await _atLookup.cramAuthenticate(at_demo_data.cramKeyMap[atSign]!);
    if (!isCramAuthSuccessful) {
      print('CRAM Authentication failed for $atSign');
      return;
    }
    print('CRAM Authentication is successful for $atSign');
    await _atLookup.close();
  } on Exception catch (e) {
    print('error while cram auth for ${atSign} exception: ${e.toString()}');
  }
}

Future<void> cramAuthAndUpdateKeys(String atSign) async {
  try {
    var _atLookup = AtLookupImpl(atSign, 'vip.ve.atsign.zone', 64);
    var isCramAuthSuccessful =
        await _atLookup.cramAuthenticate(at_demo_data.cramKeyMap[atSign]!);
    if (!isCramAuthSuccessful) {
      print('CRAM Authentication failed for $atSign');
      return;
    }
    print('CRAM Authentication is successful for $atSign');

    // Set PKAM public key
    var command =
        'update:privatekey:at_pkam_publickey ${at_demo_data.pkamPublicKeyMap[atSign]}\n';
    var response = await _atLookup.executeCommand(command, auth: true);
    if (response == 'data:-1') {
      print('Setting of PKAM public key for $atSign is successful');
    } else {
      print('Failed to update PKAM public key for $atSign');
      return;
    }

    // Set encryption public key
    command =
        'update:public:publickey${atSign} ${at_demo_data.encryptionPublicKeyMap[atSign]}\n';
    response = await _atLookup.executeCommand(command, auth: true);
    if (response!.startsWith('data:') && response != 'data:null') {
      print('Setting of encryption public key for $atSign is successful');
    } else {
      print('Failed to update encryption public key for $atSign');
      return;
    }

    // Set pkamInstalled key to "yes"
    command = 'update:public:pkaminstalled$atSign yes\n';
    response = await _atLookup.executeCommand(command, auth: true);
    if (response!.startsWith('data:') && response != 'data:null') {
      print('Set pkaminstalled key for $atSign is successful');
    } else {
      print('Failed to update pkaminstalled key for $atSign');
      return;
    }

    await _atLookup.close();
  } on Exception catch (e) {
    print('error while setting keys for ${atSign} exception: ${e.toString()}');
  }
}
