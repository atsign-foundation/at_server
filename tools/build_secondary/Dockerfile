FROM dart:3.12.0-210.1.beta@sha256:7ca43dc0a97bf5420533955af8081a76fd15c4b6f323d30fee9ef0e837c2da73 AS buildimage
ENV HOMEDIR=/atsign
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo root
# If building manually then (from the repo root):
## sudo docker build -t atsigncompany/secondary \
## -f tools/build_secondary/Dockerfile .
COPY ./packages/at_server_spec/ ./at_server_spec
COPY ./packages/at_persistence_spec/ ./at_persistence_spec
COPY ./packages/at_persistence_secondary_server/ ./at_persistence_secondary_server
COPY ./packages/at_secondary_server/ ./at_secondary_server
RUN \
  mkdir -p $HOMEDIR/storage ; \
  mkdir -p $HOMEDIR/config ; \
  mkdir -p /etc/cacert ; \
  mkdir -p /archive ; \
  cd at_persistence_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  cd ../at_secondary_server ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o secondary ; \
  addgroup --gid $GROUP_ID atsign ; \
  useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash \
    --home $HOMEDIR atsign ; \
  chown -R atsign:atsign $HOMEDIR ; \
  chown -R atsign:atsign /archive ; \
  cp config/config.yaml $HOMEDIR/config/ ; \
  cp cacert/cacert.pem /etc/cacert ; \
  cp pubspec.yaml $HOMEDIR/
# Second stage of build FROM scratch
FROM scratch
COPY --from=buildimage /runtime/ /
COPY --from=buildimage /etc/passwd /etc/passwd
COPY --from=buildimage /etc/group /etc/group
COPY --from=buildimage /etc/cacert /etc/cacert
COPY --from=buildimage --chown=atsign:atsign /app/at_secondary_server/secondary /usr/local/at/
COPY --from=buildimage --chown=atsign:atsign /atsign /atsign/
COPY --from=buildimage --chown=atsign:atsign /archive /archive/
WORKDIR /atsign
USER atsign
ENTRYPOINT ["/usr/local/at/secondary"]
