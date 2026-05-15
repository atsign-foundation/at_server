# prod_container

## Goals

- Run multiple AtServers within a single Docker container (similar to ephemeral container).
- Contains a REST API (`provision_api`) that controls the provisioning of AtServers (start, reset, delete, restart, stop). Container initially starts with 0 AtServers.
- Dynamic number of atSigns/AtServers limited only by host resources.
- Certs for `vip.ve.atsign.zone` are baked in at build time and refreshed monthly via `refreshcerts.yaml`.
- AtServer and AtDirectory storage is externalized so the container can be swarmed.
- Proxy server (`at_proxyserver`) is built into the image.

## Architecture

```mermaid
graph TD
    Client([External Client])
    HostsFile["Host /etc/hosts\n127.0.0.1 vip.ve.atsign.zone"]

    subgraph Container ["Docker Container (atsigncompany/prod_container)"]
        supervisord["supervisord (PID 1)\n/atsign/startup.sh"]

        redis["redis\nport 6379\n(localhost only)"]
        root["at_root_server\n(atDirectory)\nport 64 TLS"]
        proxy["at_proxyserver\nport 1443 TLS"]
        api["provision_api\nREST API\nport 8080"]

        secondary1["at_secondary_server\n@alice  port 5000 TLS"]
        secondary2["at_secondary_server\n@bob    port 5001 TLS"]
        secondaryN["at_secondary_server\n@...    port 500N TLS"]

        supervisord --> redis
        supervisord --> root
        supervisord --> proxy
        supervisord --> api

        root -->|"reads/writes atSign→address mappings"| redis
        proxy -->|"lookups"| root
        proxy -->|"proxies TLS"| secondary1
        proxy -->|"proxies TLS"| secondary2

        api -->|"writes supervisor conf\nsupervisorctl update"| supervisord
        api -->|"set alice vip.ve.atsign.zone:PORT"| redis
        api -->|"spawns"| secondary1
        api -->|"spawns"| secondary2
        api -->|"spawns"| secondaryN
    end

    Client -->|"POST /atSigns/alice\nGET /atSigns"| api
    Client -->|"TLS :1443"| proxy
    HostsFile -.->|"resolves vip.ve.atsign.zone\nto 127.0.0.1 for local dev"| Client
```

## Processes (managed by supervisord)

| Order | Program | Binary | Port | Notes |
|-------|---------|--------|------|-------|
| 10 | redis | `redis-server` | 6379 | localhost only, password `foobared` |
| 20 | root_server | `at_root_server` | 64 (TLS) | atDirectory; requires redis |
| 25 | proxy_server | `at_proxyserver` | 1443 (TLS) | forwards to root + secondaries |
| 30 | provision_api | `provision_api` | 8080 | REST API for AtServer lifecycle |
| dynamic | secondary | `at_secondary_server` | 5000+ (TLS) | one per atSign, managed at runtime |

## Certificates

All certs are for `vip.ve.atsign.zone` and are fetched from GitHub at image build time by the `certfetch` stage. Rebuild the image to refresh certs.

| Location | Used by | Contents | Fetched from |
|----------|---------|----------|--------------|
| `/atsign/root/certs/` | `at_root_server` | `fullchain.pem`, `privkey.pem` | `atsign-foundation/at_server` trunk — `tools/build_ephemeral_environment/ee_base/contents/atsign/root/certs/` |
| `/atsign/secondary/base/certs/` | all `at_secondary_server` instances (symlinked) | `fullchain.pem`, `privkey.pem`, `cacert.pem` | `atsign-foundation/at_server` trunk — `tools/build_ephemeral_environment/ee_base/contents/atsign/secondary/base/` |
| `/atsign/proxy/certs/` | `at_proxyserver` | `fullchain.pem`, `privkey.pem`, `cacert.pem` | `atsign-foundation/at_services` latest release — `packages/at_secondary_proxy/certs/` |

## Configuration Files

### AtDirectory
- **`contents/atsign/root/config/config.yaml`** — port, `useSSL`, cert paths.
- **`/atsign/root/certs/`** — fetched from `at_server` trunk at build time; not checked into repo.

### AtServer template
- **`contents/atsign/secondary/base/config/config.yaml`** — template config applied to every secondary. Controls TLS, storage paths, connection limits, compaction.
- **`/atsign/secondary/base/certs/`** — fetched from `at_server` trunk at build time; not checked into repo. Symlinked into each atSign's directory.

### Redis
- **`contents/etc/redis/redis.conf`** — bind address, port, `requirepass`. Password must match `-a` in `20_root_server.conf`.

### Proxy Server
- **`contents/etc/supervisor/conf.d/25_proxy_server.conf`** — process definition. Pass `-e PROXY_URL=vip.ve.atsign.zone:443` at runtime (defaults to `vip.ve.atsign.zone:443`). Binds on port 1443.
- **`/atsign/proxy/certs/`** — fetched from `at_services` latest release at build time; not checked into repo.

### Supervisor
- **`contents/etc/supervisor/supervisord.conf`** — log path (`/atsign/logs/supervisord.log`), unix socket (`/atsign/supervisor.sock`), includes both `/etc/supervisor/conf.d/*.conf` and `/atsign/supervisor/conf.d/*.conf` (the latter is where `provision_api` writes dynamic secondary confs).
- **`contents/etc/supervisor/conf.d/10_redis.conf`**
- **`contents/etc/supervisor/conf.d/20_root_server.conf`**
- **`contents/etc/supervisor/conf.d/25_proxy_server.conf`**
- **`contents/etc/supervisor/conf.d/30_provision_api.conf`**

### Startup
- **`contents/atsign/startup.sh`** — creates `/atsign/logs`, `/atsign/root`, `/atsign/secondary`, `/atsign/atservers`, `/atsign/supervisor/conf.d`, then execs `supervisord`.

## provision_api REST Endpoints

Listens on port 8080. AtSigns can be passed with or without the `@` prefix.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/atSigns` | List all provisioned atSigns with supervisord status |
| `GET` | `/atSigns/{atSign}` | Status of a single atSign |
| `POST` | `/atSigns/{atSign}` | Provision a new AtServer — generates CRAM secret, allocates port (from 5000), creates directory structure, symlinks shared certs/config, writes supervisor conf, registers address in atDirectory (redis), starts the process |
| `DELETE` | `/atSigns/{atSign}` | Stop, remove from supervisor, deregister from atDirectory |
| `POST` | `/atSigns/{atSign}/restart` | Restart the AtServer process |
| `POST` | `/atSigns/{atSign}/reset` | Wipe storage (hive, logs) and restart — CRAM and certs preserved |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_URL` | `vip.ve.atsign.zone:443` | Public-facing proxy address registered in atDirectory |
| `EXTERNAL_BASE_PORT` | *(unset — uses internal port)* | Set when the host maps a different port to the container's base port (5000). E.g. `-p 15000:5000 -e EXTERNAL_BASE_PORT=15000` |

## Commands

### Build

From repo root:

```bash
docker build \
    -f tools/build_prod_container/Dockerfile \
    -t atsigncompany/prod_container:dev \
    .
```

### Dev

Interactive — logs stream to the terminal; `Ctrl-C` stops the container.

Port 5000 is blocked on macOS by ControlCenter, so secondaries are mapped to 15000+.

```bash
docker run \
    -it \
    --rm \
    --name prod_container_dev \
    -p 1443:1443 \
    -p 8080:8080 \
    -p 15000:5000 \
    -e PROXY_URL=vip.ve.atsign.zone:443 \
    -e EXTERNAL_BASE_PORT=15000 \
    atsigncompany/prod_container:dev
```

### Prod

Detached — container restarts automatically on failure.

```bash
docker run \
    -d \
    --restart unless-stopped \
    --name prod_container \
    -p 443:1443 \
    -p 8080:8080 \
    -e PROXY_URL=vip.ve.atsign.zone:443 \
    atsigncompany/prod_container:dev
```

### Swarm / Externalized Storage

For the container to be swarmed (or simply survive restarts without losing state), four directories must be mounted as external volumes:

| Volume mount | What it holds | Consequence if lost |
|---|---|---|
| `/atsign/atservers` | Per-atSign hive storage, commit log, access log, notifications | All atSign data wiped — clients must re-onboard |
| `/atsign/supervisor/conf.d` | Dynamic supervisor confs written by `provision_api` — defines which atSigns exist | Container forgets all provisioned atSigns on restart |
| `/atsign/root` | atDirectory runtime data | atDirectory loses state |
| `/atsign/redis` | Redis RDB snapshot (see below) | atSign→address mappings lost — root server returns nothing |

Redis requires two extra steps beyond the volume mount. By default `redis.conf` has no persistence configured (pure in-memory). Edit `contents/etc/redis/redis.conf` to enable RDB snapshots and point the data directory at the mounted volume:

```
# contents/etc/redis/redis.conf
port 6379
bind 127.0.0.1
requirepass foobared
daemonize no
loglevel notice
logfile ""

dir /atsign/redis
save 60 1
```

`save 60 1` flushes a snapshot if at least 1 key changed in the last 60 seconds. Tune to taste.

**Docker run with all volumes:**

```bash
docker run \
    -d \
    --restart unless-stopped \
    --name prod_container \
    -p 1443:1443 \
    -p 8080:8080 \
    -e PROXY_URL=vip.ve.atsign.zone:443 \
    -v prod_atservers:/atsign/atservers \
    -v prod_supervisor_conf:/atsign/supervisor/conf.d \
    -v prod_root:/atsign/root \
    -v prod_redis:/atsign/redis \
    atsigncompany/prod_container:dev
```

**Docker Swarm service:**

```bash
docker service create \
    --name prod_container \
    --publish published=1443,target=1443 \
    --publish published=8080,target=8080 \
    --env PROXY_URL=vip.ve.atsign.zone:443 \
    --mount type=volume,source=prod_atservers,target=/atsign/atservers \
    --mount type=volume,source=prod_supervisor_conf,target=/atsign/supervisor/conf.d \
    --mount type=volume,source=prod_root,target=/atsign/root \
    --mount type=volume,source=prod_redis,target=/atsign/redis \
    atsigncompany/prod_container:dev
```

> **Note:** For multi-node swarm, the volumes above must be backed by a shared network filesystem (e.g. NFS, AWS EFS, GlusterFS) so all replicas see the same data. Named Docker volumes work fine for single-node deployments.

Add to `/etc/hosts` for local dev (required for TLS cert hostname validation):

```bash
sudo sh -c 'echo "127.0.0.1 vip.ve.atsign.zone" >> /etc/hosts'
```

Provision an atSign and activate:

```bash
# Provision
curl -X POST http://localhost:8080/atSigns/alice
# Returns: {"atSign":"@alice","port":5000,"cram":"<cram>"}

# Activate (using at_activate)
at_activate onboard \
    -a @alice \
    -c <cram> \
    -r vip.ve.atsign.zone \
    -k /tmp/@alice_key.atKeys \
    -y
```
