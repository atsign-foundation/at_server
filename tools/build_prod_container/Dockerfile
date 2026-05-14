FROM dart:3.11.2@sha256:f379cd388f850db3833823244f5b66c2b23ad739876467e8a3dfa72706e3eee9 AS buildimage

# Context for this Dockerfile needs to be at_server root

RUN mkdir -p /app

COPY . /app

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
  rm -rf "${AT_SERVICES_DIR}" "${AT_SERVICES_ARCHIVE}"

FROM debian:stable-20260316-slim@sha256:99fc6d2a0882fcbcdc452948d2d54eab91faafc7db037df82425edcdcf950e1f

ENV USER="atsign"
ENV GROUP_ID=1024
ENV USER_ID=1024
ENV HOMEDIR="/atsign"

RUN \
  mkdir -p ${HOMEDIR}/bin && \
  apt-get update && \
  apt-get install -y sudo redis-server supervisor curl && \
  groupadd --gid ${GROUP_ID} ${USER} && \
  useradd --system --shell /bin/bash --home ${HOMEDIR} --uid ${USER_ID} --gid ${GROUP_ID} ${USER} && \
  usermod -aG sudo ${USER} && \
  sed -i '$ a %sudo ALL=(ALL:ALL) NOPASSWD:ALL' /etc/sudoers && \
  chown -R ${USER}:${USER} ${HOMEDIR}

COPY --from=buildimage /output/at_activate ${HOMEDIR}/bin/at_activate
COPY --from=buildimage /output/provision_api ${HOMEDIR}/bin/provision_api
COPY --from=buildimage /output/at_root_server ${HOMEDIR}/bin/at_root_server
COPY --from=buildimage /output/at_secondary_server ${HOMEDIR}/bin/at_secondary_server
COPY --from=buildimage /output/at_proxyserver ${HOMEDIR}/bin/at_proxyserver

ENV PATH="${PATH}:${HOMEDIR}/bin"

USER ${USER}
WORKDIR ${HOMEDIR}

