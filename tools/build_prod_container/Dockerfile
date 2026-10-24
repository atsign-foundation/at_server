FROM dart:3.11.2@sha256:f379cd388f850db3833823244f5b66c2b23ad739876467e8a3dfa72706e3eee9 AS buildimage

# Context for this Dockerfile needs to be at_server root

RUN \
  mkdir -p /app ;

COPY . /app

# /output is where the binaries will go
# /output/at_activate
# /output/provision_api
# /output/at_root_server
# /output/at_secondary_server
# /output/at_proxyserver

RUN \
  mkdir -p /output && \
  cd /app/tools/build_prod_container/at_activate && \
  dart pub get && \
  dart compile exe ./bin/at_activate.dart -o /output/at_activate && \
  cd /app/tools/build_prod_container/provision_api && \
  dart pub get && \
  dart compile exe ./bin/provision_api.dart -o /output/provision_api && \
  cd /app/packages/at_root_server && \
  dart pub get && \
  dart compile exe ./bin/main.dart -o /output/at_root_server && \
  cd /app/packages/at_secondary_server && \
  dart pub get && \
  dart compile exe ./bin/main.dart -o /output/at_secondary_server && \
  AT_SERVICES_VERSION=$(curl --silent "https://api.github.com/repos/atsign-foundation/at_services/releases/latest" | grep -Po '(?<="tag_name": ")[^"]+') && \
  AT_SERVICES_ARCHIVE="/tmp/at_services-${AT_SERVICES_VERSION}.tar.gz" && \
  AT_SERVICES_DIR="/tmp/at_services-${AT_SERVICES_VERSION}" && \
  curl -L -o "${AT_SERVICES_ARCHIVE}" "https://github.com/atsign-foundation/at_services/archive/refs/tags/${AT_SERVICES_VERSION}.tar.gz" && \
  tar -xzf "${AT_SERVICES_ARCHIVE}" -C /tmp && \
  cd "${AT_SERVICES_DIR}" && \
  dart pub get && \
  cd "${AT_SERVICES_DIR}/packages/at_secondary_proxy" && \
  dart pub get && \
  dart compile exe bin/main.dart -o /output/at_proxyserver && \
  rm -rf "${AT_SERVICES_DIR}" "${AT_SERVICES_ARCHIVE}" ;

FROM debian:stable-20260406-slim@sha256:e51bfcd2226c480a5416730e0fa2c40df28b0da5ff562fc465202feeef2f1116 AS certfetch

# Output:
# /output/root_certs/
# /output/secondary_certs/
# /output/proxy_certs/

RUN \
  apt-get update && \
  apt-get install -y curl && \
  TRUNK="https://raw.githubusercontent.com/atsign-foundation/at_server/trunk" && \
  EE_BASE="${TRUNK}/tools/build_ephemeral_environment/ee_base/contents/atsign" && \
  mkdir -p /output/root_certs /output/secondary_certs /output/secondary_certs/mtls /output/proxy_certs && \
  curl -L -o /output/root_certs/fullchain.pem             "${EE_BASE}/root/certs/fullchain.pem" && \
  curl -L -o /output/root_certs/privkey.pem               "${EE_BASE}/root/certs/privkey.pem" && \
  curl -L -o /output/secondary_certs/fullchain.pem        "${EE_BASE}/secondary/base/certs/fullchain.pem" && \
  curl -L -o /output/secondary_certs/privkey.pem          "${EE_BASE}/secondary/base/certs/privkey.pem" && \
  curl -L -o /output/secondary_certs/cacert.pem           "${EE_BASE}/secondary/base/rootca/cacert.pem" && \
  curl -L -o /output/secondary_certs/mtls/fullchain.pem   "${EE_BASE}/secondary/base/certs/mtls/fullchain.pem" && \
  curl -L -o /output/secondary_certs/mtls/privkey.pem     "${EE_BASE}/secondary/base/certs/mtls/privkey.pem" && \
  AT_SERVICES_VERSION=$(curl --silent "https://api.github.com/repos/atsign-foundation/at_services/releases/latest" | grep -Po '(?<="tag_name": ")[^"]+') && \
  PROXY_BASE="https://raw.githubusercontent.com/atsign-foundation/at_services/${AT_SERVICES_VERSION}/packages/at_secondary_proxy/certs" && \
  curl -L -o /output/proxy_certs/fullchain.pem "${PROXY_BASE}/fullchain.pem" && \
  curl -L -o /output/proxy_certs/privkey.pem   "${PROXY_BASE}/privkey.pem" && \
  curl -L -o /output/proxy_certs/cacert.pem    "${PROXY_BASE}/cacert.pem" ;

FROM debian:stable-20260406-slim@sha256:e51bfcd2226c480a5416730e0fa2c40df28b0da5ff562fc465202feeef2f1116

ENV USER="atsign"
ENV HOMEDIR="/atsign"
ENV GROUP_ID=1024
ENV USER_ID=1024

RUN \
  apt-get update && \
  apt-get install -y sudo redis-server supervisor curl vim tree && \
  groupadd --gid ${GROUP_ID} ${USER} && \
  useradd --system --shell /bin/bash --home ${HOMEDIR} --uid ${USER_ID} --gid ${GROUP_ID} ${USER} && \
  usermod -aG sudo ${USER} && \
  sed -i '$ a %sudo ALL=(ALL:ALL) NOPASSWD:ALL' /etc/sudoers && \
  mkdir -p \
    ${HOMEDIR}/bin \
    ${HOMEDIR}/logs \
    ${HOMEDIR}/root \
    ${HOMEDIR}/secondary \
    ${HOMEDIR}/atservers \
    ${HOMEDIR}/redis \
    ${HOMEDIR}/supervisor/conf.d ;

COPY --from=buildimage /output/at_activate ${HOMEDIR}/bin/at_activate
COPY --from=buildimage /output/provision_api ${HOMEDIR}/bin/provision_api
COPY --from=buildimage /output/at_root_server ${HOMEDIR}/bin/at_root_server
COPY --from=buildimage /output/at_secondary_server ${HOMEDIR}/bin/at_secondary_server
COPY --from=buildimage /output/at_proxyserver ${HOMEDIR}/bin/at_proxyserver
COPY --from=certfetch /output/proxy_certs ${HOMEDIR}/proxy/certs
COPY --from=certfetch /output/root_certs ${HOMEDIR}/root/certs
COPY --from=certfetch /output/secondary_certs ${HOMEDIR}/secondary/base/certs

COPY tools/build_prod_container/contents /

RUN \
  chmod +x ${HOMEDIR}/startup.sh && \
  chown -R ${USER}:${USER} ${HOMEDIR} ;

ENV PATH="${PATH}:${HOMEDIR}/bin"

USER ${USER}
WORKDIR ${HOMEDIR}

CMD ["/atsign/startup.sh"]

