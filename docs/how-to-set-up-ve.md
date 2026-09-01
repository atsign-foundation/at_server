# How to set up a virtual environment

The virtual environment (VE) is primarily useful for local atPlatform testing. It runs a self-contained atPlatform instance inside a single Docker container with pre-provisioned demo atSigns, so you can start writing and testing atPlatform apps immediately without registering real atSigns.

For a more persistent and secure setup (e.g. staging, CI, or non-localhost deployments with your own DNS/TLS), see [how-to-set-up-ee.md](how-to-set-up-ee.md).

A VE container includes:

- An atDirectory (root server) on port 64
- 40 pre-provisioned atServers (secondaries) on ports 25000-25039
- A Redis database backing the root server
- supervisord managing all processes (web UI on port 9001)
- Pre-installed PKAM keys for all demo atSigns

The demo atSigns and their .atKeys files are available at:
https://github.com/atsign-foundation/at_demos/tree/trunk/packages/at_demo_data/lib/assets/atkeys

## Quick start (recommended)

Use docker compose. Copy this into a `docker-compose.yaml`:

```yaml
services:
  virtualenv:
    container_name: ve
    image: atsigncompany/virtualenv:vip
    ports:
      - '64:64'
      - '25000-25039:25000-25039'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    # Uncomment below for additional access:
    # - '127.0.0.1:6379:6379'   # Redis (only needed for direct DB inspection)
    # - '127.0.0.1:9001:9001'   # supervisord web UI (process manager)
    # - '443:443'               # atProxyServer (TLS reverse proxy for atServers)
    #
    # To route all atServer traffic through a single port (e.g. 443) instead
    # of exposing 25000-25039, set up the atProxyServer:
    # https://github.com/atsign-foundation/at_services/tree/trunk/packages/at_secondary_proxy
```

| Port | Service | Expose? |
|------|---------|---------|
| 64 | atDirectory (root server) | Yes |
| 25000-25039 | atServers (one per demo atSign) | Yes |
| 443 | atProxyServer (TLS reverse proxy for atServers) | Optional |
| 6379 | Redis | Optional, localhost only |
| 9001 | supervisord web UI | Optional, localhost only |

`extra_hosts` maps `vip.ve.atsign.zone` to localhost inside the container. Your host machine also needs to resolve it. `vip.ve.atsign.zone` already points to `127.0.0.1` via public DNS, so this works automatically if you are online. If you are offline, add it to `/etc/hosts`:

```
127.0.0.1 vip.ve.atsign.zone
```

To start:

```sh
docker compose up -d
```

To stop:

```sh
docker compose down
```

## Activating atSigns

### CRAM auth with pkamLoad (easiest)

The VE has a built-in `pkamLoad` supervisord task that CRAM-authenticates to every demo atSign and installs their PKAM public keys. It is disabled by default. To run it:

```sh
docker exec ve supervisorctl start pkamLoad
```

If running multiple VEs, replace `ve` with the `container_name` from your compose file.

Once it finishes, all demo atSigns are PKAM-ready. Use the corresponding .atKeys files in your app:
https://github.com/atsign-foundation/at_demos/tree/trunk/packages/at_demo_data/lib/assets/atkeys

### CRAM auth with at_activate

If you need to onboard a single atSign manually (or test CRAM auth), use `at_activate` with the atSign's CRAM secret:

```sh
at_activate onboard -a @alice🛠 \
  -c b26455a907582760ebf35bc4847de549bc41c24b25c8b1c58d5964f7b4f8a43bc55b0e9a601c9a9657d9a8b8bbc32f88b4e38ffaca03c8710ebae1b14ca9f364 \
  -r vip.ve.atsign.zone -v
```

The CRAM secrets for all demo atSigns are in the `at_demo_data` package:

- All CRAM secrets (text): https://github.com/atsign-foundation/at_demos/blob/trunk/packages/at_demo_data/lib/assets/cramKeys.txt
- CRAM secrets (Dart map): https://github.com/atsign-foundation/at_demos/blob/trunk/packages/at_demo_data/lib/src/at_demo_credentials.dart
- .atKeys files: https://github.com/atsign-foundation/at_demos/tree/trunk/packages/at_demo_data/lib/assets/atkeys

## Running multiple VEs side-by-side

To run multiple VEs on one host without port collisions, create a separate compose file per instance. Each VE shifts all services into a contiguous 100-port range using the `VIRTUALENV_BASE_PORT` environment variable:

```yaml
services:
  virtualenv:
    container_name: my-ve
    image: atsigncompany/virtualenv:vip
    ports:
      - '127.0.0.1:30000-30099:30000-30099'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - VIRTUALENV_BASE_PORT=30000
```

With `VIRTUALENV_BASE_PORT=30000`, services bind to:

| Service | Port |
|---------|------|
| atDirectory | 30000 (`BASE`) |
| atServers | 30001-30080 (`BASE+1` .. `BASE+80`) |
| atProxyServer | 30098 (`BASE+98`) |
| Redis | 30099 (`BASE+99`) |

For a second VE, copy the file, change the container name and base port, and run with `-f`:

```yaml
services:
  virtualenv:
    container_name: my-ve-2
    image: atsigncompany/virtualenv:vip
    ports:
      - '127.0.0.1:31000-31099:31000-31099'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - VIRTUALENV_BASE_PORT=31000
```

```sh
docker compose -f docker-compose-ve2.yaml up -d
docker exec my-ve-2 supervisorctl start pkamLoad
```
