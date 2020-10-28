![image alt <](./.github/@developersmall.png) 
### Now for a little internet optimism

# at_server
The at_server repo contains the core software implementation of the @protocol.

* [at_server_spec](./at_server_spec) is an interface abstraction that defines what 
the @server is responsible for. 

* [at_persistence](./at_persistence) is the abstracted module for persistence which can 
be replaced as desired with some other implementation.

* [at_root](./at_root) the root server is a directory that contains the most minimal 
amount of data necessary to determine where to go to ask for permission. It only 
contains a record for every @sign as well as the internet location of the associated 
secondary server that contains data and permissions.

* [at_secondary](./at_secondary) is a personal, secure server that contains a person's 
data and their permissions and terms under which they wish to share with others. The 
server is written in Dart / Flutter and is incredibly efficient. The ability to securely
sync data with other instances in the cloud or on other devices.
