FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
        fdisk \
        util-linux \
        e2fsprogs \
        dosfstools \
        mtools \
        kmod \
        qemu-user-static \
        binfmt-support \
    && rm -rf /var/lib/apt/lists/*

# qemu-user-static registers the arm64 binfmt handler on install.  The
# container must run with --privileged so binfmt_misc is writable and
# losetup/mount work.
RUN test -x /usr/bin/qemu-aarch64-static

WORKDIR /work/repo
COPY . /work/repo

ENTRYPOINT ["/bin/bash", "image-builder/build-image.sh"]
