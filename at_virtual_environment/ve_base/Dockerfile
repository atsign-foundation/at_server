FROM dart:2.17.3 AS buildimage
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo root
# If building manually then (from the repo root):
## sudo docker build -t atsigncompany/vebase \
## -f at_virtual_environment/ve_base/Dockerfile .
COPY . .
RUN \
  cd /app/at_root/at_root_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o root ; \
  cd /app/at_virtual_environment/install_PKAM_Keys ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/install_PKAM_Keys.dart -o install_PKAM_Keys

FROM debian:stable-20220622-slim
USER root

COPY ./at_virtual_environment/ve_base/contents /

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
  /app/at_root/at_root_server/root /atsign/root/
COPY --from=buildimage --chown=atsign:atsign \
  /app/at_virtual_environment/install_PKAM_Keys/install_PKAM_Keys \
  /usr/local/bin/
  