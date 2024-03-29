FROM dart:3.3.1@sha256:7e0b4e5d3773c61b5d5b42908f48853fab04c33a080c6f73ee3a99bdd1f4536e AS buildimage
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo root
# If building manually then (from the repo root):
## sudo docker build -t atsigncompany/vebase \
## -f tools/build_virtual_environment/ve_base/Dockerfile .
COPY . .
RUN \
  cd /app/packages/at_root_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o root ; \
  cd /app/tools/build_virtual_environment/install_PKAM_Keys ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/install_PKAM_Keys.dart -o install_PKAM_Keys

FROM debian:stable-20240311-slim@sha256:d10f0545d14bad5f4d230301f7e4fd904384f2dd16fda16d708f936c2fa1db3e
# was debian:stable-20221114-slim
USER root

COPY ./tools/build_virtual_environment/ve_base/contents /

RUN chmod 777 /tmp && \
    mkdir -p /atsign/logs && \
    mkdir -p /apps/logs/ && \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y -o Dpkg::Options::=--force-confdef git supervisor \
     apt-transport-https unzip wget gnupg2 redis-server && \
    groupadd --system atsign && \
    useradd --system --gid atsign --shell /bin/bash --home /apps atsign && \
    /tmp/setup/create_demo_accounts.sh

COPY --from=buildimage --chown=atsign:atsign \
  /app/packages/at_root_server/root /atsign/root/
COPY --from=buildimage --chown=atsign:atsign \
  /app/tools/build_virtual_environment/install_PKAM_Keys/install_PKAM_Keys \
  /usr/local/bin/
  