FROM dart:3.11.0@sha256:193a4d037dcef48b56f2a3544f053f4ef3b5e9865953f8f5ff2a284554da567a AS buildimage
ENV HOMEDIR=/atsign
ENV BINARYDIR=/usr/local/at
ENV USER_ID=1024
ENV GROUP_ID=1024
WORKDIR /app
# Context for this Dockerfile needs to be at_server repo packages/at_root_server
# If building manually then (from packages/at_root_server):
## sudo docker build -t atsigncompany/root .
COPY . .
RUN set -eux ; \
  mkdir -p $HOMEDIR/config ; \
  mkdir -p $BINARYDIR/config ; \
  dart pub get ; \
  dart pub update ; \
  dart compile exe bin/main.dart -o $BINARYDIR/root ; \
  addgroup --gid $GROUP_ID atsign ; \
  useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash \
    --home $HOMEDIR atsign ; \
  chown -R atsign:atsign $HOMEDIR ; \
  cp config/* $HOMEDIR/config/ ; \
  cp config/* $BINARYDIR/config/ ; \
  cp pubspec.yaml $HOMEDIR/
# Second stage of build FROM scratch
FROM scratch
COPY --from=buildimage /runtime/ /
COPY --from=buildimage /etc/passwd /etc/passwd
COPY --from=buildimage /etc/group /etc/group
COPY --from=buildimage --chown=atsign:atsign /atsign /atsign/
COPY --from=buildimage --chown=atsign:atsign /usr/local/at /usr/local/at/
WORKDIR /atsign
USER atsign
ENTRYPOINT ["/usr/local/at/root"]
