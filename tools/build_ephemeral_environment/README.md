# The Ephemeral Environment (EE)

The EE allows the creation of a full atPlatform instance in a single Docker
container, that can be used and then taken down after use with no trace.

## Building the Docker image

To build using Docker use the following command from the root of the
at_server repo:

```sh
docker build -t <dockeraccount/imagename> \
  -f tools/build_ephemeral_environment/ee_base/Dockerfile .
```

## Running the container

Run the container using the following command structure:

```sh
docker run -it -e FIRST_PORT=<start port> -p 64:64 \
  -p 127.0.0.1:9001:9001 -p <start port>-<end port>:<start port>-<end port> \
  -d dockeraccount/imagename
```

This will start the container with default certificates that are provided in
the repo to `vip.ve.atsign.zone` in the same way as the Virtual Environment
does. This is useful for testing but in actual use you will have to provide a
valid certficate files for the atServers (secondaries) and map them to
`/atsign/secondary/base/certs` using the `-v` option and then map a DNS record
to the container's IP. To tell the container the Fully Qualified DNS to
configure the atServers use the `DNS_FQDN` environment variable. In addition
the atDirectory (root) needs certifcates (which can be the same), and they can
be mapped via `-v` to `/atsign/root/certs`. The atDirectory/atServers need not
have the same DNS/cert but will have the same IP, atDirectory being on port 64
and atServers on contigious ports from `<start port>`.

Pulling this all togther an example command looks like this.

```sh
docker run -it -e DNS_FQDN="rainbow.crushware.com" \
  -v /tmp/rainbow/certs:/atsign/root/certs \
  -v /tmp/rainbow/certs:/atsign/secondary/base/certs \
  -e FIRST_PORT=2500 -p 64:64 -p 127.0.0.1:9001:9001 \
  -p 2500-2600:2500-2600 -d cconstab/emphemeral 
```

The CRAM values will be printed out in the log file of the container and they
can be used to create atKeys via at_activate for example.

```sh
at_activate onboard -a @bravo \
  -c 4df10914d207e8d70ec6d21801c4621b2e5f08bc783b8c6b182df34e3ba6c8ca \
  -r rainbow.crushware.com -v
```

Once the atKeys have been created Atsign applications can be used as normal
but with the additional argument of the new root server for example:

```sh
sshnp --root-domain rainbow.crushware.com -f @alpha -t @bravo -d test -r @zulu
```

By default 26 atSigns are created using the Phonetic Alphabet from @alpha to
@zulu. This can be overidden by creating a file listing the atSigns you
would like and mounting it at /tmp/setup/atsigns.

For example the atsigns file could contain:

```txt
one
two
three
four
five
```

This would create the five atSigns instead of the defaults, for example:

```sh
 docker run -it -e DNS_FQDN="rainbow.crushware.com" \
   -v /tmp/rainbow/certs:/atsign/root/certs \
   -v /tmp/rainbow/certs:/atsign/secondary/base/certs \
   -v/tmp/atsigns:/tmp/setup/atsigns \
   -e FIRST_PORT=2500 -p 64:64 -p 127.0.0.1:9001:9001 \
   -p 2500-2600:2500-2600 -d cconstab/emphemeral 
```

## Monitoring and administration of the running container

By default the admin interface is available via:

[http://localhost:9001/](http://localhost:9001/)

Logs of each process/atSign are visible and can be restarted if required.

A copy of the CRAM values for each atSign can be found inside the container
in the file `/tmp/CRAM_keys` if the docker logs are lost.
