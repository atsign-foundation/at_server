FROM dart:3.0.7@sha256:faf300f790cadb2e34182dd75c5f14642e21c625396055a16aa967170dfb71d7 AS buildimage
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

FROM debian:stable-20230725-slim@sha256:3c7601a0b4aad4ab731def9d67d3bfa8ec9ed3e3ac44d11720d5d54fd4a35dd5
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
  