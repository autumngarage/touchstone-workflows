# The image every linux-ephemeral job runs in (AUT-1596). It stands in for
# GitHub's ubuntu-latest for the required workflows and for the private
# consumers' own Linux jobs, so it carries what those jobs use. The base image
# brings the runner, git, jq, curl, tar, and python3. This adds what GitHub's
# image ships and these jobs use:
#   - gh, which the gate workflows call;
#   - gawk: the base's awk is mawk, which panics on regex intervals such as
#     ` {0,3}` in delivery-evidence's checker;
#   - pipx, which runs pinned Python tools (vesper's Semgrep);
#   - Node 22 LTS with npm (vesper's site validation);
#   - Swift's system dependencies, libsqlite3-dev, and a Swift toolchain,
#     which hesperus's validate builds with.
#   - xvfb, xauth and Electron's runtime libraries, which hesperus's desktop
#     startup check launches its Electron app under (`xvfb-run -a electron`).
# Rebuild it with `bash runner/linux-runner.sh build`.
#
# Pinned: the base by digest, gh and Node by release checksums, and Swift by
# release version and its release signing key. No floating installer executes.
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
    binutils gawk gcc gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libsqlite3-dev libstdc++-13-dev \
    libxml2-dev libz3-dev pipx pkg-config tzdata xz-utils zip zlib1g-dev \
    xvfb xauth libgtk-3-0t64 libnss3 libasound2t64 libgbm1 libxss1 libxtst6 \
    libatk-bridge2.0-0t64 libdrm2 libxkbcommon0 libcups2t64 libsecret-1-0; \
  rm -rf /tmp/gh.deb /var/lib/apt/lists/*

# amd64 emulation on an arm64 host. Consumers build amd64-only images (hesperus's
# worker image carries Blender's x64 release) with `--platform linux/amd64`.
# Sysbox gives each job its own empty binfmt_misc, so the VM's handler does not
# reach a job; job-entry.sh registers this static interpreter in the job's own.
# Docker's binfmt build, not Ubuntu's: noble's qemu-user-static 8.2.2 dies with
# "QEMU internal SIGSEGV" running amd64 grep, which apt setup scripts call.
COPY --from=tonistiigi/binfmt:qemu-v10.2.3@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0 /usr/bin/ /tmp/binfmt/
RUN set -eux; \
  if [ "$(dpkg --print-architecture)" = arm64 ]; then \
    install -m 0755 /tmp/binfmt/qemu-x86_64 /usr/local/bin/qemu-x86_64-static; \
    /usr/local/bin/qemu-x86_64-static --version | grep -q 'version 10.2.3'; \
  fi; \
  rm -rf /tmp/binfmt

# Docker Engine for jobs that run containers (LINUX_RUNNER_DOCKER=dind): each
# such job starts its own daemon inside its Sysbox container, whose storage is
# deleted with the job, so no job reaches another's containers, the VM or the
# host's engine. Pinned by Docker's release signing key and exact versions.
ARG DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
ARG DOCKER_CE_VERSION=5:29.10.0-1~ubuntu.24.04~noble
ARG CONTAINERD_VERSION=2.4.2-4~ubuntu.24.04~noble
ARG BUILDX_VERSION=0.39.1-1~ubuntu.24.04~noble
RUN set -eux; \
  install -m 0755 -d /etc/apt/keyrings; \
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc; \
  test "$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '/^fpr/ {print $10; exit}')" = "$DOCKER_KEY_FINGERPRINT"; \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends iptables \
    "docker-ce=${DOCKER_CE_VERSION}" "docker-ce-cli=${DOCKER_CE_VERSION}" \
    "containerd.io=${CONTAINERD_VERSION}" "docker-buildx-plugin=${BUILDX_VERSION}"; \
  usermod -aG docker runner; \
  rm -rf /var/lib/apt/lists/*

ARG NODE_VERSION=22.23.2
ARG NODE_SHA256_ARM64=fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8
ARG NODE_SHA256_X64=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) node_arch=x64; sum="$NODE_SHA256_X64" ;; \
    arm64) node_arch=arm64; sum="$NODE_SHA256_ARM64" ;; \
    *) echo "unsupported architecture $arch" >&2; exit 1 ;; \
  esac; \
  curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"; \
  echo "${sum}  /tmp/node.tar.xz" | sha256sum --check --strict; \
  tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner; \
  rm -f /tmp/node.tar.xz; \
  node --version; \
  npm --version

# Same signed archive used by the official Swift container. Do not execute
# the floating Swiftly bootstrap: it crashes under x64 emulation (AUT-2593).
ARG SWIFT_VERSION=6.3.3
ARG SWIFT_SIGNING_KEY=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
RUN set -eux; \
  case "$(dpkg --print-architecture)" in \
    amd64) suffix='' ;; \
    arm64) suffix='-aarch64' ;; \
    *) echo 'unsupported Swift architecture' >&2; exit 1 ;; \
  esac; \
  archive="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404${suffix}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04${suffix}.tar.gz"; \
  curl -fsSL "$archive" -o /tmp/swift.tar.gz; \
  curl -fsSL "$archive.sig" -o /tmp/swift.tar.gz.sig; \
  export GNUPGHOME="$(mktemp -d)"; \
  gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$SWIFT_SIGNING_KEY"; \
  gpg --batch --verify /tmp/swift.tar.gz.sig /tmp/swift.tar.gz; \
  mkdir /opt/swift; \
  tar -xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1 --no-same-owner; \
  chmod -R a+rX /opt/swift; \
  rm -rf "$GNUPGHOME" /tmp/swift.tar.gz /tmp/swift.tar.gz.sig
ENV PATH=/opt/swift/usr/bin:$PATH
USER runner
# The same nonroot user that runs CI can compile and execute, not just print
# a version. This also detects missing runtime libraries after installation.
RUN set -eux; \
  probe="$(mktemp -d)"; \
  printf 'print("runner Swift works")\n' > "$probe/main.swift"; \
  swift --version; \
  swiftc "$probe/main.swift" -o "$probe/probe"; \
  test "$("$probe/probe")" = 'runner Swift works'; \
  rm -rf "$probe"
# Last, so a change to the entry script rebuilds only this layer. COPY
# writes it as root whatever USER says, and keeps its committed 0755 mode.
COPY job-entry.sh /usr/local/bin/job-entry.sh
