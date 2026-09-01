# How to set up a virtual environment

A virutal environment contains a couple of things:

- Virtual environment Atsigns. Their .atKeys can be fetched from https://github.com/atsign-foundation/at_demos/tree/trunk/packages/at_demo_data/lib/assets/atkeys
- an atDirectory server
- Everything that is needed to fulfill the two items above such as a redis database, the Dart runtime, and more.

## Dockerfile

The most famous way to spin up a virtual environment is this Dockerfile

https://hub.docker.com/r/atsigncompany/virtualenv

### docker-compose

A sample docker compose file

```yml
version: '2'
services:
  virtualenv:
    image: atsigncompany/virtualenv:vip
    ports:
      - "127.0.0.1:6379:6379"
      - "64:64"
      - "443:443"
      - "127.0.0.1:9001:9001"
      - "25000-25999:25000-25999"
    extra_hosts:
      - "vip.ve.atsign.zone:127.0.0.1"
```

This makes it easy to view which ports to forward, such as 6379 which is the redis database, 64 for the atDirectry, 9001 for supervisord I think, and 25000-25999 for the atServers.

## Proxy Service

If you want everything to go through one egress port (such as 443), you can set up a proxy server. See

at_proxyserver: https://github.com/atsign-foundation/at_services/tree/trunk/packages/at_secondary_proxy

More notably, there's `packages/at_secondary_proxy/tools/Dockerfile` and a `at_proxyserver.yml`.


