#!/bin/sh
sleep 10
cat /tmp/records | redis-cli --pipe
# keep the shell alive!
sleep 100000000
