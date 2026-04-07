FROM alpine:3.20

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    curl \
    iproute2 \
    iputils

CMD ["sh", "-c", "trap : TERM INT; sleep 365d & wait"]
