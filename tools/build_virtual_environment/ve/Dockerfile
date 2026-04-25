FROM atsigncompany/vebase:latest
USER root

# Secondary binary will be put in place by GitHub Actions
# Context for this Dockerfile is its local directory:
# tools/build_virtual_environment/ve
COPY ./contents /

EXPOSE 64 443 6379 9001

ENV DART_VM_OPTIONS='--use_compactor --dontneed_on_sweep --old_gen_growth_time_ratio=50 --old_gen_growth_space_ratio=10 --new_gen_semi_max_size=8'

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]