FROM atsigncompany/vebase:latest
USER root

# Secondary binary will be put in place by GitHub Actions
# Context for this Dockerfile is its local directory:
# tools/build_virtual_environment/ve
COPY ./contents /

EXPOSE 64 443 6379 9001

ENV DART_VM_OPTIONS='--scavenger_tasks=5,--use_compactor,--marker_tasks=5,--compactor_tasks=5,--idle_duration_micros=10000,--old_gen_growth_time_ratio=50,--old_gen_growth_space_ratio=5,--mark_when_idle'

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]