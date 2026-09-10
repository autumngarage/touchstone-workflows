# The image every linux-ephemeral job runs in (AUT-1596). It stands in for
# GitHub's ubuntu-latest for the required workflows and for the private
# consumers' own Linux jobs, so it carries what those jobs use. The base image
# brings the runner, git, jq, curl, tar, and python3. This adds gh, which the
# gate workflows call; Swift's system dependencies and libsqlite3-dev; and a
# Swift toolchain, which hesperus's validate builds with. Rebuild it with
# `bash runner/linux-runner.sh build`.
#
# Pinned: the base by digest, gh by its release checksum. swiftly verifies the
# toolchain's signature against swift.org's keys.
FROM ghcr.io/actions/actions-runner:2.337.0@sha256:e5496277be5d09bc968b3d64911b74e219ac4a3f2edce956a3ecf9271bea1ef4

USER root
ARG GH_VERSION=2.100.0
ARG GH_SHA256_AMD64=698c8d88cc19cc92bfe96bad58d10b2a5b274c52433d6dc57799c81f6139d5fc
ARG GH_SHA256_ARM64=33ccd2ad7ce639c927e1cb209e36555b0e1fbb89f7a38239c0568040ec758612
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) sum="$GH_SHA256_AMD64" ;; \
    arm64) sum="$GH_SHA256_ARM64" ;; \
    *) echo "unsupported architecture $arch" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/gh.deb "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.deb"; \
  echo "${sum}  /tmp/gh.deb" | sha256sum --check --strict; \
  apt-get update; \
  apt-get install -y --no-install-recommends /tmp/gh.deb \
    binutils gcc gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev \
    libxml2-dev libz3-dev pkg-config tzdata xz-utils zlib1g-dev; \
  rm -rf /tmp/gh.deb /var/lib/apt/lists/*

USER runner
ARG SWIFT_VERSION=6.2
# swiftly's env.sh is bash; the default RUN shell is dash.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eux; \
  curl -fsSL -o /tmp/swiftly.tar.gz "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"; \
  tar -xzf /tmp/swiftly.tar.gz -C /tmp; \
  /tmp/swiftly init --quiet-shell-followup --assume-yes --skip-install; \
  . "$HOME/.local/share/swiftly/env.sh"; \
  swiftly install --use "$SWIFT_VERSION" --assume-yes; \
  rm -f /tmp/swiftly /tmp/swiftly.tar.gz; \
  swift --version
ENV PATH=/home/runner/.local/share/swiftly/bin:$PATH
