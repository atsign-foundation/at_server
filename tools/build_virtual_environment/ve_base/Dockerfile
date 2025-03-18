FROM dart:3.7.2@sha256:d024672257408ae61773904bb6934ea89549a874a2bd0a4d18d42241cb6a5eed AS buildimage
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

FROM debian:stable-20250317-slim@sha256:beeaa68cce7fcc913bd0b2f47cf1a3f1cd7c510d791a213da001b5feb92c4920
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
  