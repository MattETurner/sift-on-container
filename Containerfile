FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Keep the container build rooted in this repository. install.sh owns the full
# SIFT bootstrap so it can patch Cast/Salt state before installing recovery tools.
COPY install.sh /usr/local/sbin/sift-container-install
RUN chmod +x /usr/local/sbin/sift-container-install && \
    SIFT_CONTAINER_BUILD=1 \
    SIFT_ASSUME_YES=1 \
    SIFT_ALLOW_PARTIAL=1 \
    /usr/local/sbin/sift-container-install && \
    mkdir -p /evidence && \
    chown sift:sift /evidence && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/*

USER sift
WORKDIR /evidence
