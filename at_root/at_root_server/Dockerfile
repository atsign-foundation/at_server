FROM ubuntu:latest
RUN mkdir /usr/local/at
ENV APP_BINARY=/usr/local/at
COPY root $APP_BINARY/
ENV HOME=/atsign
RUN mkdir -p $HOME
ENV USER_ID=1024
ENV GROUP_ID=1024
RUN addgroup --gid $GROUP_ID atsign
RUN useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash --home $HOME atsign
RUN mkdir $HOME/config
RUN mkdir $APP_BINARY/config
COPY config/* $HOME/config/
COPY pubspec.yaml $HOME/
COPY config/* $APP_BINARY/config/
RUN chown -R atsign:atsign $HOME
USER atsign
WORKDIR $HOME
ENTRYPOINT ["/usr/local/at/root"]
