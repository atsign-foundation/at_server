#!/bin/sh
sleep 15
cat /tmp/records | redis-cli --pipe
sleep infinity
