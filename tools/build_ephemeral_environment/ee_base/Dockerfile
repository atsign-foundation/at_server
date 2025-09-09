FROM dart:3.9.2@sha256:cc4d50f840b502dde7068fca505efedad0802817b15b78218b4512396717464a AS buildimage
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

FROM debian:stable-20250908-slim@sha256:0c80836db6d5bd1f89ed3c1300bbd888fc8a415130a52fd86e501ce38471fe5b
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
  