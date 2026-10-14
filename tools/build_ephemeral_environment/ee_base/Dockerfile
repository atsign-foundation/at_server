FROM dart:3.13.4@sha256:33faf91bc941466a767ce845b4bbb5d578ecd180abe5ee243e9c8c039109d215 AS buildimage
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo root
# If building manually then (from the repo root):
## sudo docker build -t atsigncompany/vebase \
## -f tools/build_virtual_environment/ee_base/Dockerfile .
COPY . .
RUN \
  cd /app/packages/at_root_server && \
  dart pub get && \
  dart pub update && \
  dart compile exe bin/main.dart -o root && \
  cd /app/packages/at_persistence_secondary_server && \
  dart pub get && \
  dart pub update && \
  cd /app/packages/at_secondary_server && \
  dart pub get && \
  dart pub update && \
  dart compile exe bin/main.dart -o secondary && \
  cd /app/tools/build_ephemeral_environment/at_activate && \
  dart pub get && \
  dart pub update && \
  dart compile exe bin/at_activate.dart -o at_activate

FROM debian:stable-20261005-slim@sha256:eb593cf2c358cacef45ca0a424bbc7d30cfa3466265fc2662b9466a0ca6ba1c5
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

ENV DART_VM_OPTIONS='--use_compactor,--dontneed_on_sweep,--old_gen_growth_time_ratio=50,--old_gen_growth_space_ratio=10,--new_gen_semi_max_size=8'

# Run supervisor configuration file on container startup
CMD ["/tmp/startup.sh"]
