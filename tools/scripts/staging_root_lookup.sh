#!/bin/bash
(echo $1; sleep 1) | openssl s_client -brief -connect root.atsign.wtf:64 \
  2>/dev/null | grep --color=none "^@.*:" | cut -d'@' -f2