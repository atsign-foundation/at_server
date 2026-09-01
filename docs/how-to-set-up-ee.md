# How to set up an ephemeral environment

The ephemeral environment (EE) creates a full atPlatform instance in a single Docker container that can be spun up and torn down with no trace. Unlike the VE (see [how-to-set-up-ve.md](how-to-set-up-ve.md)), the EE generates atSigns and CRAM secrets at startup rather than shipping pre-provisioned demo keys. This makes it better suited for:

- Staging and CI pipelines (fresh atSigns per run, no shared state)
- Non-localhost deployments with your own DNS and TLS certificates
- Scenarios where you want to control exactly which atSigns exist

An EE container includes:

- An atDirectory (root server)
- Up to 80 atServers (secondaries), one per atSign
- A Redis database backing the root server
- supervisord managing all processes (web UI on port 9001)
- A bundled `at_activate` binary for onboarding atKeys

## Quick start (recommended)

Use docker compose. Copy this into a `docker-compose.yaml`:

```yaml
services:
  ephemeral:
    container_name: ee
    image: atsigncompany/ephemeral:latest
    ports:
      - '127.0.0.1:2500-2599:2500-2599'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - EPHEMERAL_BASE_PORT=2500
      # - DNS_FQDN=rainbow.example.com  # default: vip.ve.atsign.zone
    # Uncomment below for custom DNS/TLS or custom atSigns:
    # volumes:
    #   - /path/to/certs:/atsign/root/certs
    #   - /path/to/certs:/atsign/secondary/base/certs
    #   - /path/to/atsigns-file:/tmp/setup/atsigns
    #
    # To route all atServer traffic through a single port (e.g. 443) instead
    # of exposing a port range, set up the atProxyServer:
    # https://github.com/atsign-foundation/at_services/tree/trunk/packages/at_secondary_proxy
```

`vip.ve.atsign.zone` already points to `127.0.0.1` via public DNS. If you are offline, add it to `/etc/hosts`:

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

## Port layout

With `EPHEMERAL_BASE_PORT=2500`, services bind to:

| Service | Port | Expose? |
|---------|------|---------|
| atDirectory | 2500 (`BASE`) | Yes |
| atServers | 2501-2580 (`BASE+1` .. `BASE+80`) | Yes |
| (reserved) | 2581-2598 (`BASE+81` .. `BASE+98`) | No |
| Redis | 2599 (`BASE+99`) | Optional, localhost only |

All ports in the compose example are bound to `127.0.0.1` to avoid exposing services to the network.

## Activating atSigns

### Getting CRAM secrets

By default, 26 atSigns are created using the NATO phonetic alphabet (@alpha through @zulu). Their CRAM secrets are printed to the container log on startup:

```sh
docker compose logs ephemeral
```

The output contains lines like:

```
alpha		4df10914d207e8d70ec6d21801c4621b2e5f08bc783b8c6b182df34e3ba6c8ca
bravo		a1b2c3d4e5f6...
```

The first column is the atSign name (without `@`), the second is the CRAM secret.

If the logs are lost, the secrets are also stored inside the container at `/tmp/CRAM_Keys`:

```sh
docker exec ee cat /tmp/CRAM_Keys
```

To extract a single atSign's CRAM secret (e.g. @bravo):

```sh
docker exec ee grep '^bravo' /tmp/CRAM_Keys | awk '{print $2}'
```

### Onboarding with at_activate

Use `at_activate` with a CRAM secret to generate .atKeys files:

```sh
at_activate onboard -a @bravo \
  -c <cram-secret-from-logs> \
  -r vip.ve.atsign.zone -v
```

If using a non-default root domain:

```sh
at_activate onboard -a @bravo \
  -c <cram-secret-from-logs> \
  -r rainbow.example.com -v
```

Once onboarded, the .atKeys file is written locally and the atSign is PKAM-ready. Use atPlatform apps as normal, passing the root domain if it is not the default:

```sh
sshnp --root-domain rainbow.example.com -f @alpha -t @bravo -d test -r @zulu
```

## Custom atSigns

To override the default 26 atSigns, create a file listing one atSign name per line (without the `@` prefix):

```txt
one
two
three
four
five
```

Mount it into the container at `/tmp/setup/atsigns`:

```yaml
volumes:
  - /path/to/my-atsigns:/tmp/setup/atsigns
```

## Custom DNS and TLS

For non-localhost deployments, set `DNS_FQDN` and mount your TLS certificates:

```yaml
environment:
  - EPHEMERAL_BASE_PORT=2500
  - DNS_FQDN=rainbow.example.com
volumes:
  - /path/to/certs:/atsign/root/certs
  - /path/to/certs:/atsign/secondary/base/certs
```

The atDirectory and atServers can share the same certificate. The DNS record must resolve to the container's IP.

## Proxy server

To route all atServer traffic through a single port instead of exposing the full `BASE+1` .. `BASE+80` range, add the `at_proxyserver` container alongside the EE:

```yaml
services:
  ephemeral:
    container_name: ee
    image: atsigncompany/ephemeral:latest
    ports:
      - '127.0.0.1:2500:2500'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - EPHEMERAL_BASE_PORT=2500

  proxy:
    container_name: ee-proxy
    image: atsigncompany/at_proxyserver
    command: >-
      --proxy-url vip.ve.atsign.zone:443
      --root-url vip.ve.atsign.zone:2500
      --bind-port 443
      --cert-dir /atsign/certs
    ports:
      - '443:443'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    # volumes:
    #   - /path/to/certs:/atsign/certs  # mount your own certs for non-localhost
```

With this setup, clients connect to `vip.ve.atsign.zone:443` and the proxy routes to the correct atServer internally. You only expose two ports: 2500 (atDirectory) and 443 (proxy).

## Running multiple EEs side-by-side

To run multiple EEs on one host, create a separate compose file per instance with a different base port:

```yaml
name: ee-a
services:
  ephemeral:
    container_name: ee-a
    image: atsigncompany/ephemeral:latest
    ports:
      - '127.0.0.1:2500-2599:2500-2599'
    extra_hosts:
      - 'vip.ve.atsign.zone:127.0.0.1'
    environment:
      - EPHEMERAL_BASE_PORT=2500
      - DNS_FQDN=vip.ve.atsign.zone
```

For a second EE, copy the file, change the name, container name, and base port (e.g. 2600), and `docker compose -f <file> up -d`.

ee-a's atDirectory is on port 2500, ee-b's on port 2600. No port collisions.

## Monitoring

Expose port 9001 to access the supervisord web UI at `http://localhost:9001/`. From there you can view logs and restart individual atSign processes.

To expose it, add to the ports list:

```yaml
ports:
  - '127.0.0.1:2500-2599:2500-2599'
  - '127.0.0.1:9001:9001'
```
