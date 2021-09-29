## Running an observable secondary on the staging environment

Log onto buzz-01

### Get the secondary service name

```bash
~cconstab/seccheck/sa2d atsign
```

Will return something like (in this case for @funnelcakepresent):

```bash
d9d7e5e9-d5e8-587d-858a-0b023724e8e5.buzz.do-sf2.atsign.zone:3124
```

So the secondary service name will be `d9d7e5e9-d5e8-587d-858a-0b023724e8e5_secondary`

### Set env variables

```bash
MYSECONDARY=d9d7e5e9-d5e8-587d-858a-0b023724e8e5_secondary
MYPORT=3124
```

### Increase the memory limit

As a VM will take a lot more room than an AOT binary:

```bash
sudo docker service update --limit-memory 250M $MYSECONDARY
```

### Switch to the observable image

```bash
sudo docker service update --image \
reg.buzz.do-sf2.atsign.zone/atsigncompany/secondary:dev_obs \
$MYSECONDARY
```

### Map an additional port

In this case adding 10000 to the base port to be the observable port:

```bash
sudo docker service update --publish-add 1$MYPORT:8181 $MYSECONDARY
```

### Get the authentication token

```bash
sudo docker service logs $MYSECONDARY | grep Observatory
```

Will return something like:

```
d9d7e5e9-d5e8-587d-858a-0b023724e8e5_secondary.1.ztbkolssbgee@buzz-02    | Observatory listening on http://0.0.0.0:8181/TUyGYPx5FtI=/
```

Where `TUyGYPx5FtI=` is the authentication token.

You can now browse to:

http://buzz.lb.atsign.zone:13124/TUyGYPx5FtI=

The same URL can be used in [Dart DevTools](https://dart.dev/tools/dart-devtools).

## Some other useful commands

### Get the container ID

```bash
sudo docker service ls | grep secondary | grep $MYPORT
```

Will return something like:

```
mp9uizay15mp        d9d7e5e9-d5e8-587d-858a-0b023724e8e5_secondary   replicated          1/1                 reg.buzz.do-sf2.atsign.zone/atsigncompany/secondary:dev_env   *:3124->3124/tcp
```

### Find the mount point

```bash
CONTAINERID = mp9uizay15mp
sudo docker inspect -f '{{json .Spec.TaskTemplate.ContainerSpec.Mounts }}' "$CONTAINERID" | jq .
```

Will return something like:

```json
[
  {
    "Type": "bind",
    "Source": "/gluster/@/secondaries/d5/dc/ba/57/d5dcba5743e1b25d1dd13d3713898462/d9d7e5e9-d5e8-587d-858a-0b023724e8e5",
    "Target": "/atsign"
  },
  {
    "Type": "bind",
    "Source": "/etc/letsencrypt/live/d9d7e5e9-d5e8-587d-858a-0b023724e8e5.buzz.do-sf2.atsign.zone",
    "Target": "/atsign/certs"
  },
  {
    "Type": "volume",
    "Target": "/atsign/config"
  }
]
```