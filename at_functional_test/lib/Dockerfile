# Inherit ubuntu base image
FROM ubuntu:latest
USER root

# Update linux package repo and install desired dependencies
RUN apt-get update -y
RUN apt-get -y  upgrade
RUN apt-get -y install git supervisor apt-transport-https unzip wget gnupg2 redis-server

# Create new linux group and user to own apps
RUN groupadd --system atsign
RUN useradd --system --gid atsign --shell /bin/bash --home /apps atsign

# Create directory for app logs
RUN mkdir -p /atsign/logs
run mkdir -p /apps/logs/

# RUN any other configuration or dependency setup commands for apps
RUN mkdir -p /atsign/root
COPY ./root/root /atsign/root/
RUN mkdir -p /atsign/root/config
COPY ./root/config/* /atsign/root/config/
RUN mkdir -p /atsign/root/certs
COPY ./root/certs/* /atsign/root/certs/
COPY ./secondary/ /atsign/secondary/

#Copy in redis.conf
COPY ./redis/redis.conf /etc/redis/redis.conf
COPY ./redis/records /tmp/records

#setup the demo @signs
COPY ./setup /tmp/setup
RUN chmod 755 /tmp/setup/create_demo_accounts.sh
RUN chmod 755 /tmp/setup/createConf
# the joy of windows and \r
RUN sed -i 's/\r//g' /tmp/setup/create_demo_accounts.sh
RUN sed -i 's/\r//g' /tmp/setup/createConf
RUN ls -l /tmp/setup
RUN /tmp/setup/create_demo_accounts.sh
RUN ls /etc/supervisor/conf.d

# Copy in the install_pkam_Keys dart executable
COPY ./install_pkam_keys/install_pkam_keys /usr/local/bin/
RUN chmod 755 /usr/local/bin/install_pkam_keys

#COPY ./redis/import.sh /tmp/import.sh to get redis loaded and then install the PKAMS
RUN echo "#!/bin/sh" > /tmp/import.sh
RUN echo "sleep 15" >> /tmp/import.sh
RUN echo "cat /tmp/records | redis-cli --pipe" >> /tmp/import.sh
RUN echo "sleep 10000000" >> /tmp/import.sh
RUN chmod 755 /tmp/import.sh

RUN echo "#!/bin/sh" >  /tmp/pkam.sh
RUN echo "sleep 25" >> /tmp/pkam.sh
RUN echo "/usr/local/bin/install_pkam_keys" >> /tmp/pkam.sh
RUN echo "sleep 10000000" >> /tmp/pkam.sh
RUN chmod 755 /tmp/pkam.sh


# Copy in supervisor configuration files
COPY ./supervisord/conf.d/* /etc/supervisor/conf.d/

#Expose the ports
EXPOSE 6379
EXPOSE 64
EXPOSE 9001

CMD ["supervisord", "-n"]
