import 'package:at_commons/at_commons.dart';

class Response {
  String _data;
  String _type;
  bool _isError = false;
  String _errorMessage;
  String errorCode;
  AtException atException;

  bool get isError => _isError;

  bool isStream = false;

  @override
  String toString() {
    return 'Response{_data: ${_data}, _type: $_type, _isError: $_isError, _errorMessage: $_errorMessage}';
  }

  set isError(bool value) {
    _isError = value;
  }

  String get errorMessage => _errorMessage;

  set errorMessage(String value) {
    _errorMessage = value;
  }

  String get type => _type;

  set type(String value) {
    _type = value;
  }

  String get data => _data;

  set data(String value) {
    _data = value;
  }
}
