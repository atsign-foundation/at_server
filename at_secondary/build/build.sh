#!/bin/bash
# Get all the code we need to build
cd ../at_persistence_secondary_server
pub get
pub update
cd ../at_secondary_server
pub get
pub update

#Run unit tests before building binary
#pub run test --concurrency=1
# 
#Generate the binary
dart compile exe  bin/main.dart -o secondary