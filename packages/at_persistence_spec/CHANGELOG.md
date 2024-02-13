## 3.0.0
- breaking_change: replaced optional params in put/create methods with metadata from at_commons
## 2.0.14
- feat: add optional param skipCommit to keystore - put,create and remove methods
## 2.0.12
- feat: Added new optional encryption metadata parameters to the WritableKeystore spec for `put` and `create`
## 2.0.11
- refactor: Added to specs to address some leaky abstractions
## 2.0.10
- fix: Add AtCompaction spec for keystore compaction 
## 2.0.9
- fix: rollback keystore delete KeyNotFoundException
## 2.0.8
- fix dart analyzer issue
- documentation changes
## 2.0.7
- Add optional parameter 'encoding' to put and create method in keystore to support encoding of new line characters 
## 2.0.6
- Added support for @server/@client annotation for separating server-specific/client-specific methods
## 2.0.5
- Added encryption shared key and public key checksum to metadata
- Compaction statistics measures entries count, previously measured log size
## 2.0.4
- Support to collect and store compaction statistics
## 2.0.3
- Add isKeyExists method to keystore
## 2.0.2
- Support for Hive lazy and in memory boxes 
## 2.0.1
- Change Hive box type to lazy box
## 2.0.0
- Null safety upgrade
## 1.0.1+3
- Support multiple atsigns
  Introduced batch verb for sync  
## 1.0.1+2
- getEntries() renamed to getFirstNEntries in compaction strategy
## 1.0.1+1
- Method renaming in compaction strategy
## 1.0.1
- Documentation related changes
## 1.0.0
- Initial version, created by Stagehand


