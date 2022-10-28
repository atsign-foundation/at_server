## Running an observable secondary on the staging environment

Log onto staging0001-01 (the easy way to do this is with the
[gssh](https://gist.github.com/cpswan/1d26d8071caf83dce2ad55d1df378388#file-gssh)
helper script e.g. `gssh staging0001-01`).

### Get the secondary service name

```bash
~cconstab/seccheck/sa2d atsign
```

Will return something like (in this case for @thecreative52):

```bash
a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2.staging0001.atsign.zone:1104
```

So the secondary service name will be `a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2_secondary`

### Set env variables

```bash
MYSECONDARY=a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2_secondary
MYPORT=1104
```

### Increase the memory limit

As a VM will take a lot more room than an AOT binary:

```bash
sudo docker service update --limit-memory 250M $MYSECONDARY
```

### Switch to the observable image

```bash
sudo docker service update --image \
reg.staging0001.atsign.zone/atsigncompany/secondary:dev_obs \
$MYSECONDARY
```

### Map an additional port

In this case adding 10000 to the base port to be the observable port:

```bash
sudo docker service update --publish-add 1$MYPORT:8181 $MYSECONDARY
```

### Get the authentication token

```bash
sudo docker service logs $MYSECONDARY | grep "Dart VM"
```

Will return something like:

```
a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2_secondary.1.ztbkolssbgee@staging0001-02    | The Dart VM service is listening on http://0.0.0.0:8181/TUyGYPx5FtI=/
```

Where `TUyGYPx5FtI=` is the authentication token.

You can now browse to:

http://staging0001-01.lb.atsign.zone:13124/TUyGYPx5FtI=

The same URL can be used in [Dart DevTools](https://dart.dev/tools/dart-devtools).

## To return it back to normal

### Switch back to the regular image

```bash
sudo docker service update --image \
reg.staging0001.atsign.zone/atsigncompany/secondary:dev_env \
$MYSECONDARY
```

### Return to usual memory limit

```bash
sudo docker service update --limit-memory 50M $MYSECONDARY
```

### Remove additional port map

```bash
sudo docker service update --publish-rm 8181 $MYSECONDARY
```

### Check that secondary is responsive

```bash
~cconstab/seccheck/checksecondary.expect $MYPORT
```

## Some other useful commands

### Get the container ID

```bash
sudo docker service ls | grep secondary | grep $MYPORT
```

Will return something like:

```
mp9uizay15mp        a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2_secondary   replicated          1/1                 reg.staging0001.atsign.zone/atsigncompany/secondary:dev_env   *:1104->1104/tcp
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
    "Source": "/etc/letsencrypt/live/a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2.staging0001.atsign.zone",
    "Target": "/atsign/certs"
  },
  {
    "Type": "bind",
    "Source": "/gluster/@/secondaries/93/5d/b1/1e/935db11ecec498537cb0824b22c7d221/a18e1f6d-b893-5b6c-94c9-ad47dbcfefc2/storage",
    "Target": "/atsign/storage"
  }
]
```