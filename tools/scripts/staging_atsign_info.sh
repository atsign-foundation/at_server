#!/bin/bash
(echo info:brief; sleep 1) | openssl s_client -brief -connect $1 \
  2>/dev/null | grep --color=none "^@.*:" | cut -d'@' -f2 | sed -e s/data://