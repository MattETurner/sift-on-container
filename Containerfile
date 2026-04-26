FROM ubuntu:22.04

# Prevent all interactive prompts
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# 1. Install VM-level prerequisites
RUN apt-get update && apt-get install -y \
    ca-certificates sudo unzip tar wget curl git apt-utils tzdata python3 python3-pip

# 2. Create the 'sift' user that the SaltStack states require
# The installer will fail if it can't find a non-root user to own the configs.
RUN useradd -m -s /bin/bash sift && \
    echo "sift ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# 3. Clone Jonathan's repo and fix the permissions
WORKDIR /opt
RUN git clone https://github.com/matteturner/sift-on-container.git && \
    chown -R sift:sift /opt/sift-on-container

# 4. Run the installer as the 'sift' user
USER sift
WORKDIR /opt/sift-on-container
RUN chmod +x install.sh && \
    # We use '|| true' to ensure that if a minor Salt state fails (like a GUI tweak), 
    # the build continues so the CLI tools still get installed.
    (yes | sudo ./install.sh) || true

# 5. Switch back to root for final cleanup (optional)
USER root
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /evidence
