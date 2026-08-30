#!/bin/bash
#
if [[ $# -eq 0 || $# -gt 1 ]] ; then
    echo 'Usage create <Filename listing atSigns to create>'
    exit 0
fi


#Use incoming Enviroment variables if set
if [ -n "${DNS_FQDN+1}" ]; then
  echo "\$DNS_FQDN is set to $DNS_FQDN"
  sed -i 's/DNS_FQDN/'$DNS_FQDN'/g' /atsign/secondary/base/config/config.yaml
else
  echo "\$DNS_FQDN is not set, setting to default"
  DNS_FQDN="vip.ve.atsign.zone"
  sed -i 's/DNS_FQDN/'$DNS_FQDN'/g' /atsign/secondary/base/config/config.yaml
  echo "\$DNS_FQDN is set to $DNS_FQDN"
fi

if [ -n "${FIRST_PORT+1}" ]; then
  echo "\$FIRST_PORT is set to $FIRST_PORT"
else
  echo "\$FIRST_PORT is not set, setting to 1024"
  FIRST_PORT="1024"
fi


for ATSIGN in $(cat $1)
do

export env CRAM=$(head -c 32 /dev/urandom | xxd -p -c 32)

# Print the CRAM Keys
printf "$ATSIGN		$CRAM\n"
printf "$ATSIGN		$CRAM\n" >> /tmp/CRAM_Keys

cp  TEMPLATE.conf /etc/supervisor/conf.d/${FIRST_PORT}_${ATSIGN}.conf
mkdir /atsign/atservers/${ATSIGN}
ln -s /atsign/secondary/base/certs /atsign/atservers/${ATSIGN}/certs
ln -s /atsign/secondary/base/config /atsign/atservers/${ATSIGN}/config

sed -i 's/ATSIGN/'$ATSIGN'/g' /etc/supervisor/conf.d/${FIRST_PORT}_${ATSIGN}.conf
sed -i 's/CRAM/'$CRAM'/g' /etc/supervisor/conf.d/${FIRST_PORT}_${ATSIGN}.conf
sed -i 's/PORT/'$FIRST_PORT'/g' /etc/supervisor/conf.d/${FIRST_PORT}_${ATSIGN}.conf
echo $CRAM > /atsign/atservers/${ATSIGN}/CRAM

#
#Add records to redis

printf "set ${ATSIGN} $DNS_FQDN:${FIRST_PORT}\r\n" >> /tmp/records
((FIRST_PORT++))
done