FROM atsigncompany/buildimage AS buildimage
WORKDIR /app
COPY . .
WORKDIR /app/build
RUN ./build.sh
# Set up the @ environment
ENV APP_BINARY=/usr/local/at
WORKDIR /app
COPY at_secondary_server/secondary $APP_BINARY/
ENV HOME=/atsign
RUN mkdir -p $HOME
RUN mkdir -p /archive
ENV USER_ID=1024
ENV GROUP_ID=1024
RUN addgroup --gid $GROUP_ID atsign
RUN useradd --system --uid $USER_ID --gid $GROUP_ID --shell /bin/bash --home $HOME atsign
RUN chown -R atsign:atsign $HOME
RUN chown -R atsign:atsign /archive
#USER atsign
RUN mkdir $HOME/storage
RUN mkdir $HOME/config
COPY at_secondary_server/config/* $HOME/config/
#COPY pubspec.yaml $HOME/
RUN chown -R atsign:atsign $HOME/storage
#RUN ls -la $HOME/config
RUN ls -la $HOME/
WORKDIR $HOME
# Now go slim with an almost scracth container
FROM atsigncompany/runimage
COPY --from=buildimage /etc/passwd /etc/passwd
COPY --from=buildimage /etc/group /etc/group
COPY --from=buildimage --chown=atsign:atsign /usr/local/at/secondary /usr/local/at/
COPY --from=buildimage --chown=atsign:atsign /atsign /atsign/
COPY --from=buildimage --chown=atsign:atsign /archive /archive/
WORKDIR /atsign
USER atsign
ENTRYPOINT ["/usr/local/at/secondary"]