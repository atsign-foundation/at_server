FROM atsigncompany/vebase:latest
USER root

# Secondary binary will be put in place by GitHub Actions
# Context for this Dockerfile is its local directory:
# tools/build_virtual_environment/ve
COPY ./contents /

EXPOSE 64 443 6379 9001

ENV DART_VM_OPTIONS="--use_compactor,--force_evacuation,--idle_duration_micros=0,--compactor_tasks=5,--marker_tasks=5,--scavenger_tasks=5,--old_gen_growth_time_ratio=50,--old_gen_growth_space_ratio=10"

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]