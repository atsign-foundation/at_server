FROM dart:3.7.2@sha256:6e280d1bbf1a3cb4da1ad2ff77307c6c8e5375d6fec155d1ea8734da6f03e5d6 AS buildimage
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo root
# If building manually then (from the repo root):
## sudo docker build -t atsigncompany/vebase \
## -f tools/build_virtual_environment/ee_base/Dockerfile .
COPY . .
RUN \
  cd /app/packages/at_root_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o root ; \
  cd /app/packages/at_persistence_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  cd /app/packages/at_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o secondary; \
  cd /app/tools/build_ephemeral_environment/at_activate ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/at_activate.dart -o at_activate

FROM debian:stable-20250317-slim@sha256:70b337e820bf51d399fa5bfa96a0066fbf22f3aa2c3307e2401b91e2207ac3c3
# was debian:stable-20221114-slim
USER root

COPY ./tools/build_ephemeral_environment/ee_base/contents /

RUN chmod 777 /tmp && \
    mkdir -p /atsign/logs && \
    mkdir -p /apps/logs/ && \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y -o Dpkg::Options::=--force-confdef git supervisor xxd \
     apt-transport-https unzip wget gnupg2 redis-server && \
    groupadd --system atsign && \
    useradd --system --gid atsign --shell /bin/bash --home /apps atsign 
    # && \
    #/tmp/setup/create_demo_accounts.sh

COPY --from=buildimage --chown=atsign:atsign \
  /app/packages/at_root_server/root /atsign/root/
COPY --from=buildimage --chown=atsign:atsign \
  /app/tools/build_ephemeral_environment/at_activate/at_activate \
  /usr/local/bin/


  # Secondary binary and pubspec.yaml from first stage
COPY --from=buildimage --chown=atsign:atsign \
/app/packages/at_secondary_server/secondary /atsign/secondary/
COPY --from=buildimage --chown=atsign:atsign \
/app/packages/at_secondary_server/pubspec.yaml /atsign/secondary/

# Run supervisor configuration file on container startup
CMD ["/tmp/startup.sh"]
  