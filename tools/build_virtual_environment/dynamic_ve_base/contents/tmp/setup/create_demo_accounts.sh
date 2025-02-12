#!/bin/bash
cd /tmp/setup

config_file="/mnt/setup/atservers"

while read -r line; do
  atsign=$(echo "$line" | sed -e 's/^\(.*\)\w+.*\w+.*$/\1/')
  if ! cat /tmp/records | grep -q "^set $atsign"; then
    ./createConf $line # intentional word splitting
  fi
done <"$config_file"
