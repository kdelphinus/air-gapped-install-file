ARG BUILDAH_BASE_IMAGE=quay.io/buildah/stable:v1.41.4
FROM ${BUILDAH_BASE_IMAGE}

USER root

RUN dnf -y install \
      ca-certificates \
      findutils \
      git \
      grep \
      openssh-clients \
      sed \
      shadow-utils \
      tar \
      gzip \
      which \
    && dnf clean all \
    && if ! id -u jenkins >/dev/null 2>&1; then useradd -u 1000 -m -s /bin/bash jenkins; fi \
    && mkdir -p /home/jenkins/.config/containers /home/jenkins/.local/share/containers /workspace /tmp/run-1000 \
    && chown -R 1000:1000 /home/jenkins /workspace /tmp/run-1000 \
    && chmod 700 /tmp/run-1000

COPY containers-storage.conf /home/jenkins/.config/containers/storage.conf

ENV BUILDAH_ISOLATION=chroot
ENV STORAGE_DRIVER=vfs
ENV XDG_RUNTIME_DIR=/tmp/run-1000

USER 1000
WORKDIR /workspace
