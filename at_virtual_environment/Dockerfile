FROM debian:stable-20220228-slim
USER root

# TODO compile install_PKAM_Keys

COPY ./contents /
RUN chmod 777 /tmp && \
    mkdir -p /atsign/logs && \
    mkdir -p /apps/logs/ && \
    #mkdir -p /atsign/root/config && \
    #mkdir -p /atsign/root/certs && \
    apt-get update && apt-get upgrade -y && \
    apt-get install -y -o Dpkg::Options::=--force-confdef git supervisor \
     apt-transport-https unzip wget gnupg2 redis-server && \
    groupadd --system atsign && \
    useradd --system --gid atsign --shell /bin/bash --home /apps atsign && \
    /tmp/setup/create_demo_accounts.sh

EXPOSE 64 6379 9001

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]