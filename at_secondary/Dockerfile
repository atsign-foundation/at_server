FROM atsigncompany/buildimage AS buildimage
ENV HOME=/atsign
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
COPY . .
RUN \
  cd at_persistence_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  cd ../at_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o secondary ; \
  mkdir -p $HOME/storage ; \
  mkdir -p $HOME/config ; \
  mkdir -p /archive ; \
  addgroup --gid $GROUP_ID atsign ; \
  useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash \
  --home $HOME atsign ; \
  chown -R atsign:atsign $HOME ; \
  chown -R atsign:atsign /archive ; \
  cp config/config.yaml $HOME/config/ ; \
  cp pubspec.yaml $HOME/
# Second stage of build FROM scratch
FROM scratch
COPY --from=buildimage /runtime/ /
COPY --from=buildimage /etc/passwd /etc/passwd
COPY --from=buildimage /etc/group /etc/group
COPY --from=buildimage --chown=atsign:atsign /app/at_secondary_server/secondary /usr/local/at/
COPY --from=buildimage --chown=atsign:atsign /atsign /atsign/
COPY --from=buildimage --chown=atsign:atsign /archive /archive/
WORKDIR /atsign
USER atsign
ENTRYPOINT ["/usr/local/at/secondary"]
