# prod_container

## Goals of the "Production Container"

- Run multiple AtServers within a single Docker container (similar to ephemeral container).
- Contains a REST API that controls the provisioning of AtServers (start, reset, delete, restart, stop, etc,.). Container initially starts with 0 AtServers by default.
- Dynamic number of Atsigns/AtServers can exist at a time, limited by the resources that the container is running on.
- Out of the box option 1: contains `vip.ve.atsign.zone` certificates . We will need a workflow that updates Dockerhub images so that certificates are kept up-to-date .
- Out of the box option 2: pass a Docker volume that uses your own certs
- AtServer and AtDirectory storage is externalized so that the container can be swarmed
- Proxy server is built into the image .

## Commands

Build:

```bash
docker build \
    -f tools/build_prod_container/Dockerfile \
    -t atsigncompany/prod_container:dev \
    .
```

Run:

```bash
docker run \
    -it \
    --rm \
    atsigncompany/prod_container:dev \
    /bin/bash
```

Build and Run:

```bash
docker build \
    -f tools/build_prod_container/Dockerfile \
    -t atsigncompany/prod_container:dev \
    . && \
docker run \
    -it \
    --rm \
    atsigncompany/prod_container:dev \
    /bin/bash
```
