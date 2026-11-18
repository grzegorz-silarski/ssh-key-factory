ARG PACKAGE_REPOSITORY=https://dl-cdn.alpinelinux.org
FROM alpine:3.23

ARG PACKAGE_REPOSITORY
RUN case "$PACKAGE_REPOSITORY" in \
      https://*[!A-Za-z0-9._:/-]*) echo "Invalid PACKAGE_REPOSITORY" >&2; exit 1 ;; \
      https://*) ;; \
      *) echo "PACKAGE_REPOSITORY must use https://" >&2; exit 1 ;; \
    esac && \
    sed -i -E "s~https?://dl-cdn.alpinelinux.org~${PACKAGE_REPOSITORY}~g" /etc/apk/repositories && \
    apk add --no-cache openssh-keygen putty && \
    cp /etc/passwd /etc/passwd.base && \
    ln -sf /tmp/passwd /etc/passwd

COPY entrypoint.sh askpass.sh /var/ssh-keygen/
RUN chmod 0555 /var/ssh-keygen/entrypoint.sh /var/ssh-keygen/askpass.sh

USER 65534:65534
ENTRYPOINT [ "/var/ssh-keygen/entrypoint.sh" ]
