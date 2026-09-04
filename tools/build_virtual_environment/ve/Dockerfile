FROM atsigncompany/vebase:latest
USER root

# libsqlite3 for the SQLite persistence backend's FFI — needed when the
# secondary runs with persistenceBackend=sqlite or =dual (e.g. the
# dual-write DB-identity functional run). Harmless for the default hive mode.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# Secondary binary will be put in place by GitHub Actions
# Context for this Dockerfile is its local directory:
# tools/build_virtual_environment/ve
COPY ./contents /

EXPOSE 64 443 6379 9001

# Every atServer in the virtual environment runs with testingMode on. The
# environment exists to be provisioned by force: pkamLoad installs each demo
# atSign's keypair by CRAM-authenticating and writing the legacy PKAM
# credential, a write the atServer refuses in every other mode and, under
# testingMode, redirects into the `primary` enrollment. Any client harness that
# starts this image and then runs pkamLoad depends on it, so it is baked in
# here rather than left to each harness's `docker run -e`. The server reads
# the environment variable ahead of config.yaml, so the base image's
# `testingMode: false` is overridden for every process supervisord starts.
ENV testingMode=true

ENV DART_VM_OPTIONS='--use_compactor,--dontneed_on_sweep,--old_gen_growth_time_ratio=50,--old_gen_growth_space_ratio=10,--new_gen_semi_max_size=8'

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]