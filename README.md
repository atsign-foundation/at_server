<img width=250px src="https://atsign.dev/assets/img/@platform_logo_grey.svg?sanitize=true">

[![Build Status](https://github.com/atsign-foundation/at_server/actions/workflows/at_server.yaml/badge.svg?branch=trunk)](https://github.com/atsign-foundation/at_server/actions/workflows/at_server.yaml)
[![GitHub License](https://img.shields.io/badge/license-BSD3-blue.svg)](./LICENSE)

# at_server
The at_server repo contains the core software implementation of the atProtocol.

* [at_server_spec](./at_server_spec) is an interface abstraction that defines what 
the atServer is responsible for. 

* [at_persistence](./at_persistence) is the abstracted module for persistence which can 
be replaced as desired with some other implementation.

* [at_root](./at_root) the root server is a directory that contains the most minimal 
amount of data necessary to determine where to go to ask for permission. It only 
contains a record for every Atsign as well as the internet location of the associated 
secondary server that contains data and permissions.

* [at_secondary](./at_secondary) is a personal, secure server that contains a person's 
data and their permissions and terms under which they wish to share with others. The 
server is written in Dart / Flutter and is incredibly efficient. The ability to securely
sync data with other instances in the cloud or on other devices.
