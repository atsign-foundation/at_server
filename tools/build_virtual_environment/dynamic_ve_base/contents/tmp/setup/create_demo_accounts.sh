#!/bin/bash
cd /tmp/setup

config_file="/mnt/setup/atservers"

while read -r line; do
  echo "line: $line"
  ./createConf $line # intentional word splitting
done <"$config_file"
