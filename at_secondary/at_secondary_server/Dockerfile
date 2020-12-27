FROM ubuntu:latest
# Create new linux group and user to own apps
ENV APP_BINARY=/usr/local/at
COPY secondary $APP_BINARY/
ENV HOME=/atsign
RUN mkdir -p $HOME
ENV USER_ID=1024
ENV GROUP_ID=1024
RUN addgroup --gid $GROUP_ID atsign
RUN useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash --home $HOME atsign
RUN chown -R atsign:atsign $HOME
RUN chown -R atsign:atsign /archive
USER atsign
RUN mkdir $HOME/storage
RUN mkdir $HOME/config
COPY config/* $HOME/config/
RUN chown -R atsign:atsign $HOME/storage
#RUN ls -la $HOME/config
RUN ls -la $HOME/
WORKDIR $HOME
ENTRYPOINT ["/usr/local/at/secondary"]
