# Use a minimal base image
FROM debian:bullseye

# Set environment variables for non-interactive installation
ENV DEBIAN_FRONTEND=noninteractive HOME=/root
ENV PATH=${HOME}/bin:$PATH

# Install required packages
RUN echo "nameserver 1.1.1.1" > /etc/resolv.conf && echo "nameserver 8.8.8.8" >> /etc/resolv.conf \
    && apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    wget \
    libgnutls30 \
    git \
    python3 \
    python3-pip \
    python3-lxml \
    pkg-config \
    build-essential \
    file \
    zip \
    nano \
    libssl-dev \
    libncurses-dev \
    ca-certificates \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Ensure the PATH is updated persistently
RUN mkdir -p ${HOME}/bin \
    && echo 'export PATH=${HOME}/bin:$PATH' >> ${HOME}/.bashrc

# Install torrent7z (adjusted for Makefile location)
RUN git clone https://github.com/BubblesInTheTub/torrent7z.git /tmp/torrent7z \
    && cd /tmp/torrent7z/linux_src/p7zip_4.65 \
    && make \
    && install -Dm 0755 bin/t7z "${HOME}/bin"

# Install mktorrent (from the pobrn repository)
RUN git clone https://github.com/pobrn/mktorrent.git /tmp/mktorrent \
    && cd /tmp/mktorrent \
    && PREFIX=${HOME} make && PREFIX=${HOME} make install \
    && rm -rf /tmp/mktorrent

# Install pkg2zip
RUN git clone https://github.com/lusid1/pkg2zip.git /tmp/pkg2zip \
    && cd /tmp/pkg2zip \
    && make && make install \
    && rm -rf /tmp/pkg2zip

# Install fzf from upstream releases instead of apt - Debian bullseye's
# packaged version predates the "load" bind-event the scripts rely on
# for pre-selecting DLC by default, and errors out with "unsupported
# key: load" instead of running.
RUN case "$(dpkg --print-architecture)" in \
        amd64) FZF_ARCH=amd64 ;; \
        arm64) FZF_ARCH=arm64 ;; \
        *) echo "Unsupported architecture for fzf: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && FZF_VERSION="$(curl -fsSL https://api.github.com/repos/junegunn/fzf/releases/latest | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')" \
    && curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_${FZF_ARCH}.tar.gz" -o /tmp/fzf.tar.gz \
    && mkdir -p "${HOME}/bin" \
    && tar -xzf /tmp/fzf.tar.gz -C "${HOME}/bin" \
    && chmod +x "${HOME}/bin/fzf" \
    && rm /tmp/fzf.tar.gz

RUN pip3 install requests

# Seed a copy of nopaystation_scripts outside of /app so it can repopulate
# /app on container startup if it's mounted empty (e.g. an empty bind mount)
RUN git clone https://github.com/thetigeregg/nopaystation_scripts.git /opt/nps-seed/nopaystation_scripts \
    && cd /opt/nps-seed/nopaystation_scripts \
    && chmod +x nps_*.sh pyNPU.py \
    && mkdir -p "${HOME}/bin" \
    && for f in nps_*.sh pyNPU.py; do ln -s "/app/nopaystation_scripts/$f" "${HOME}/bin/$f"; done

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set the working directory for the container
WORKDIR /app

ENTRYPOINT ["/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]