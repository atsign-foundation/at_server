#!/bin/sh
/tmp/setup/create_demo_accounts.sh

supervisord -n
