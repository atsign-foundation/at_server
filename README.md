<img width=250px src="https://atsign.dev/assets/img/atPlatform_logo_gray.svg?sanitize=true">

[![Build Status](https://github.com/atsign-foundation/at_server/actions/workflows/at_server.yaml/badge.svg?branch=trunk)](https://github.com/atsign-foundation/at_server/actions/workflows/at_server.yaml)
[![GitHub License](https://img.shields.io/badge/license-BSD3-blue.svg)](./LICENSE)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/atsign-foundation/at_server/badge)](https://api.securityscorecards.dev/projects/github.com/atsign-foundation/at_server)

# at_server
This repo contains the core software implementation of the atProtocol:

## packages

### core runtime services

* [at_root_server](./packages/at_root_server) the root server is a directory
that contains the fully qualified domain name (FQDN) and port for secondary
servers. This is the most minimal amount of data necessary to determine where
to go to ask for permission. It only contains a record for every atSign as
well as the Internet location of the associated secondary server that
contains data and permissions.

* [at_secondary_server](./packages/at_secondary_server) the secondary server
is a personal, secure server that contains a person's data and their
permissions and terms under which they wish to share with others. The server
is written in Dart and is incredibly efficient. It has the ability to
securely sync data with other instances in the cloud or on other devices.

### core dependencies

* [at_server_spec](./packages/at_server_spec) is an interface abstraction
that defines what the atServer is responsible for. 

* [at_persistence_spec](./packages/at_persistence_spec) is the abstracted
module for persistence which can be replaced as desired with some other
implementation.

## tests

* [at_functional_test](./tests/at_functional_test/) is a set of self
contained tests that make use of at_virtual_environment to run an entire
mini atSign infrastructure within a single container.

* [at_end2end_test](./tests/at_end2end_test/) is a suite of tests that
cannot be run standalone, and instead make use of a number of
[dess](https://github.com/atsign-foundation/dess) atSigns hosted on
virtual machines. Tests are arranged so that cross testing happens between
the version under test, and production releases.

## tools

* the virtual environment makes use of certificates that need to be refreshed
on a regular basis, which is done with a GitHub Action that runs the
`acme_certs.py` script.

* the cicd1 and cicd2 directories also contains the scripts used by
the dess VMs for end2end tests that ensure the correct images for version
cross testing.

* [build_virtual_environment](./tools/build_virtual_environment/) contains
the Dockerfiles and dependencies used to build the virtual environment
base image `ve_base` the virtual environment on that base, and the
`install_PKAM_Keys` tool that's used to initialise a virtual environment.

* [build_secondary](./tools/build_secondary/) contains the Dockerfiles
used to build various flavours of secondary server.
