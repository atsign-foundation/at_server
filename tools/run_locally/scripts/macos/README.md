# macos scripts

## Prerequisites

1. Have redis

```bash
brew install redis
```

2. In your `redis.conf` (either in `/usr/local/etc/redis.conf` or `/opt/homebrew/etc/redis.conf`)

Ensure this line is uncommented

```
requirepass foobared
```

## Instructions

1. Start Redis:

```bash
tools/run_locally/scripts/macos/at_redis
```

2. Start the root server:

```bash
tools/run_locally/scripts/macos/at_root
```

That script starts packages/at_root_server/bin/main.dart and points it at Redis:

```bash
dart packages/at_root_server/bin/main.dart \
    -h vip.ve.atsign.zone \
    -p 6379 \
    -a foobared
```

Here -h, -p, and -a are Redis host, Redis port, and Redis auth. They are not the root server’s public port.

3. Start one AtServer per atSign, each on a unique port:

```bash
tools/run_locally/scripts/macos/at_server -a @alice -p 25000 -s alice-secret
tools/run_locally/scripts/macos/at_server -a @bob   -p 25001 -s bob-secret
tools/run_locally/scripts/macos/at_server -a @carol -p 25002 -s carol-secret
```

The at_server script does two important things:

```redis
set alice vip.ve.atsign.zone:25000
    -a @alice \
    -p 25000 \
    -s alice-secret
```

So the shape is:

Redis
alice -> vip.ve.atsign.zone:25000
bob   -> vip.ve.atsign.zone:25001

AtServer for @alice listens on 25000
AtServer for @bob listens on 25001

The important rule: each AtServer needs its own atSign, port, and storage directory. The provided script handles the storage separation with paths like storage_@alice, storage_@bob, etc.
