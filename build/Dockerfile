# syntax=docker/dockerfile:1.10
# The ref defaults are branch heads. build/build-images.sh passes the pins
# from build/sources.env.

# renovate: datasource=docker depName=ubuntu
ARG UBUNTU_IMAGE=ubuntu:24.04
# The chart's podSecurityContext runs the pods with this uid and gid.
ARG APP_UID=1000
# classic, tbc or wotlk: the suffix of the CMaNGOS repository names.
ARG EXPANSION=classic

FROM ${UBUNTU_IMAGE} AS builder
ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build ccache git ca-certificates \
      libboost-program-options-dev libboost-thread-dev libboost-regex-dev \
      libboost-serialization-dev libboost-filesystem-dev \
      libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev

ARG EXPANSION
ARG CORE_REPO=https://github.com/cmangos/mangos-${EXPANSION}.git
ARG CORE_REF=master
ARG PLAYERBOTS_REPO=https://github.com/cmangos/playerbots.git
ARG PLAYERBOTS_REF=master

# CMake reads the revision from .git, and mangosd prints it at startup.
ADD --keep-git-dir=true ${CORE_REPO}#${CORE_REF} /src/core
# Without this checkout, CMake FetchContent clones playerbots at master. The
# configure step still needs the network: the core fetches zlib the same way.
ADD ${PLAYERBOTS_REPO}#${PLAYERBOTS_REF} /src/core/src/modules/PlayerBots

# Each compiler process can use more than 1 GiB of memory.
ARG BUILD_JOBS=0
ARG CMAKE_BUILD_TYPE=Release
ENV CCACHE_DIR=/ccache \
    CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime \
    CCACHE_MAXSIZE=5G
RUN --mount=type=cache,target=/ccache,id=cmangos-${EXPANSION}-ccache \
    set -eux; \
    jobs="$BUILD_JOBS"; [ "$jobs" != 0 ] || jobs="$(nproc)"; \
    cmake -S /src/core -B /build -G Ninja \
      -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
      -DCMAKE_INSTALL_PREFIX=/opt/cmangos \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DBUILD_GAME_SERVER=ON \
      -DBUILD_LOGIN_SERVER=ON \
      -DBUILD_EXTRACTORS=ON \
      -DBUILD_PLAYERBOTS=ON \
      -DBUILD_AHBOT=ON \
      -DFETCHCONTENT_SOURCE_DIR_PLAYERBOTS=/src/core/src/modules/PlayerBots; \
    cmake --build /build --parallel "$jobs"; \
    cmake --install /build; \
    cp /src/core/contrib/extractor_scripts/config.json /opt/cmangos/bin/tools/; \
    ccache --show-stats || true; \
    # A cache miss rebuilds this layer as a whole, so the object files are of no
    # use after the install. They would only bloat the layer and the build cache.
    rm -rf /build
RUN git -C /src/core rev-parse HEAD > /opt/cmangos/REVISION

# Boost links statically (Boost_USE_STATIC_LIBS in the core CMakeLists.txt).
FROM ${UBUNTU_IMAGE} AS runtime
ARG DEBIAN_FRONTEND=noninteractive
ARG APP_UID
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip xz-utils \
      libmysqlclient21 libssl3t64 zlib1g libbz2-1.0 \
 && userdel --remove ubuntu \
 && groupadd --gid "$APP_UID" cmangos \
 && useradd --uid "$APP_UID" --gid "$APP_UID" --home-dir /opt/cmangos --no-create-home --shell /usr/sbin/nologin cmangos

FROM runtime AS server
ARG APP_UID
ARG EXPANSION
COPY --from=builder /opt/cmangos /opt/cmangos
COPY --chmod=0755 scripts/extract-client-data.sh /usr/local/bin/cmangos-extract
# The servers refuse to start without a .conf file. The chart sets the values
# through Mangosd_*, Realmd_* and PlayerBots_* environment variables.
RUN set -eux; \
    cd /opt/cmangos/etc; \
    for f in *.conf.dist; do cp "$f" "${f%.dist}"; done; \
    mkdir -p /opt/cmangos/data /opt/cmangos/logs; \
    chown cmangos:cmangos /opt/cmangos/logs; \
    ldd /opt/cmangos/bin/mangosd /opt/cmangos/bin/realmd /opt/cmangos/bin/tools/* 2>/dev/null \
      | grep 'not found' && exit 1 || true
ENV CMANGOS_EXPANSION=${EXPANSION} \
    Mangosd_DataDir=/opt/cmangos/data \
    Mangosd_LogsDir=/opt/cmangos/logs \
    Realmd_LogsDir=/opt/cmangos/logs
# The playerbots module reads ../etc/aiplayerbot.conf relative to the working
# directory.
WORKDIR /opt/cmangos/bin
USER ${APP_UID}:${APP_UID}
EXPOSE 3724 8085
CMD ["/opt/cmangos/bin/mangosd", "-c", "/opt/cmangos/etc/mangosd.conf"]

FROM ${UBUNTU_IMAGE} AS db
ARG DEBIAN_FRONTEND=noninteractive
ARG APP_UID
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates mysql-client gzip python3 \
 && userdel --remove ubuntu \
 && groupadd --gid "$APP_UID" cmangos \
 && useradd --uid "$APP_UID" --gid "$APP_UID" --home-dir /tmp --no-create-home --shell /usr/sbin/nologin cmangos

ARG EXPANSION
ARG DB_REPO=https://github.com/cmangos/${EXPANSION}-db.git
ARG DB_REF=master
ADD ${DB_REPO}#${DB_REF} /opt/cmangos/db
# InstallFullDB.sh reads CORE_PATH/sql and the playerbots SQL from the core tree.
COPY --from=builder /src/core/sql /opt/cmangos/core/sql
COPY --from=builder /src/core/src/shared/revision_sql.h /opt/cmangos/core/src/shared/revision_sql.h
COPY --from=builder /src/core/src/modules/PlayerBots/sql/characters /opt/cmangos/core/src/modules/PlayerBots/sql/characters
COPY --from=builder /src/core/src/modules/PlayerBots/sql/world/*.sql /opt/cmangos/core/src/modules/PlayerBots/sql/world/
COPY --from=builder /src/core/src/modules/PlayerBots/sql/world/${EXPANSION} /opt/cmangos/core/src/modules/PlayerBots/sql/world/${EXPANSION}
COPY --chmod=0755 scripts/db-init.sh /usr/local/bin/cmangos-db-init
COPY --chmod=0755 scripts/srp6.py /usr/local/bin/cmangos-srp6
COPY --chmod=0755 scripts/auth-check.py /usr/local/bin/cmangos-auth-check
# Fingerprint of every input to a world database install. The db-init
# script reinstalls the world database when this value changes.
RUN set -eux; \
    cd /opt/cmangos; \
    find db core/sql/base core/sql/scriptdev2 core/src/modules/PlayerBots/sql/world \
      -type f \( -name '*.sql' -o -name '*.gz' \) -print0 \
      | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 > /opt/cmangos/world-content.sha256; \
    cat /opt/cmangos/world-content.sha256
ENV CMANGOS_EXPANSION=${EXPANSION}
USER ${APP_UID}:${APP_UID}
WORKDIR /tmp
CMD ["/usr/local/bin/cmangos-db-init"]
