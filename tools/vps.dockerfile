FROM docker.io/ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ARG SSH_PUBLIC_KEY

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    openssh-server \
    systemd \
    systemd-sysv \
  && rm -rf /var/lib/apt/lists/* \
  && install -d -m 0700 /root/.ssh \
  && printf '%s\n' "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys \
  && chmod 0600 /root/.ssh/authorized_keys \
  && printf '%s\n' \
    'PermitRootLogin prohibit-password' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    > /etc/ssh/sshd_config.d/99-topics-club-vps.conf \
  && install -d -m 0755 /etc/docker \
  && printf '%s\n' '{"storage-driver":"overlay2","features":{"containerd-snapshotter":false}}' \
    > /etc/docker/daemon.json \
  && systemctl enable ssh

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
