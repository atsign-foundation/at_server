#!/bin/bash

dart pub get

rm -rf ./storage
mkdir storage

pushd ../at_secondary/at_secondary_server
dart bin/main.dart --server_port=25000 --at_sign="@alice🛠" --shared_secret='b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364' >& ../../at_functional_test/storage/server.log 2>&1 &
pid=$!
popd

dart test

kill $pid
