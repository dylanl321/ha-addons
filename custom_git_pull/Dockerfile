ARG BUILD_FROM
FROM $BUILD_FROM

# Setup base
RUN apk add --no-cache jq curl git openssh-client rsync socat openssl \
    python3 py3-aiohttp

# Copy data
COPY data/lib/ /lib/
COPY data/web/ /web/
COPY data/run.sh /

CMD [ "/run.sh" ]
