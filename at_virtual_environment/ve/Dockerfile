FROM atsigncompany/vebase:latest
USER root

# Secondary binary will be put in place by GitHub Actions
# Context for this Dockerfile is its local directory:
# at_virtual_environment/ve
COPY ./contents /

EXPOSE 64 6379 9001

# Run supervisor configuration file on container startup
CMD ["supervisord", "-n"]