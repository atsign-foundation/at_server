///Class to get configurable data.
class Configuration {
  ///list of blocked atsigns.
  final List<String> _blockList;

  Configuration(this._blockList);

  ///fetches blocklist.
  List<String> get blockList => _blockList;

  Map toJson() => {
        'blockList': _blockList,
      };

  @override
  String toString() {
    return 'Configuration{BlockList: ${_blockList.join(',')}}';
  }
}
