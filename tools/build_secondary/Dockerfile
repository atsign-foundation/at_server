FROM dart:3.13.2@sha256:1f86408456fbcdc5f9c33fa267d3680d86e79c255ec338b9a215459224769770 AS buildimage
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
  apt-get update ; \
  apt-get install -y --no-install-recommends libsqlite3-0 ; \
  rm -rf /var/lib/apt/lists/* ; \
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

# Stage the architecture-appropriate libsqlite3 (+ its libz dependency) into
# /runtime, alongside the Dart AOT runtime, so the scratch stage's static
# `COPY --from=buildimage /runtime/ /` picks up the correct library for the
# build architecture (a scratch-stage COPY cannot be arch-conditional).
# `--dereference` resolves the SONAME symlink so a real file lands in the
# scratch image (a copied symlink would dangle). Only dlopen'd at runtime when
# persistence.backend=sqlite (the default hive image never loads it). NOTE:
# confirm the full transitive .so set with a Docker build before the first
# SQLite production deploy (this scratch image has no package manager).
RUN \
  case "$(dpkg --print-architecture)" in \
    amd64) TRIPLET="x86_64-linux-gnu" ;; \
    armhf) TRIPLET="arm-linux-gnueabihf" ;; \
    arm64) TRIPLET="aarch64-linux-gnu" ;; \
    riscv64) TRIPLET="riscv64-linux-gnu" ;; \
    *) echo "Unsupported architecture: $(dpkg --print-architecture)" ; exit 5 ;; \
  esac ; \
  FILES="/usr/lib/$TRIPLET/libsqlite3.so.0 /usr/lib/$TRIPLET/libz.so.1" ; \
  for f in $FILES ; do \
    mkdir -p "/runtime$(dirname "$f")" ; \
    cp --archive --link --dereference --no-target-directory "$f" "/runtime$f" ; \
  done

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
ENV DART_VM_OPTIONS='--use_compactor,--dontneed_on_sweep,--old_gen_growth_time_ratio=50,--old_gen_growth_space_ratio=10,--new_gen_semi_max_size=8'
ENTRYPOINT ["/usr/local/at/secondary"]
