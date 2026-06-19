# syntax=docker/dockerfile:1.6
#
# Single-container fleet image. One container per robot complex; all 5 procs
# (zenohd + persistence + application_gateway + notification_service +
# farm_soil + rancho_water) inside, supervised by /app/start.sh.
#
# Build: from the fleet_design/ root, run packaging/build.sh — it stages the
# prebuilt zenoh-pico .so files into packaging/build_assets/ then invokes
# `docker build -f packaging/Dockerfile .`.
#
# Today: native arm64 on the WSL host (Apple Silicon). Same arch as the Pi 4
# target, so the image is portable to the Pi without buildx.
#
# zenohd comes from Eclipse's official Debian APT repo (glibc-linked, matches
# our base — the docker.io/eclipse/zenoh image is musl/Alpine-built and
# doesn't run on debian without alpine's libgcc).

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- Add Eclipse zenoh APT repo --------------------------------------------
# trusted=yes pending: pin Eclipse's signing key once we move to production.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg \
    && echo "deb [trusted=yes] https://download.eclipse.org/zenoh/debian-repo/ /" \
        > /etc/apt/sources.list.d/zenoh.list \
    && rm -rf /var/lib/apt/lists/*

# ---- Runtime + build deps + zenohd -----------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        gcc \
        libc6-dev \
        libsqlite3-0 \
        libsqlite3-dev \
        libssl3 \
        libssl-dev \
        luajit \
        luarocks \
        make \
        sqlite3 \
        tini \
        zenoh \
    && luarocks --lua-version=5.1 install luasocket \
    && luarocks --lua-version=5.1 install luasec \
    && luarocks --lua-version=5.1 install lua-cjson \
    && luarocks --lua-version=5.1 install lsqlite3 \
    && rm -rf /var/lib/apt/lists/*

# ---- Build the SQLite ltree extension --------------------------------------
COPY vendor/c/ltree /tmp/ltree
RUN cd /tmp/ltree && make && make install && rm -rf /tmp/ltree

# ---- Bring in prebuilt zenoh-pico + custom binding shims -------------------
# Staged into packaging/build_assets/lib/ by packaging/build.sh from the
# user's bench locations (~/src/zenoh-pico/, ~/knowledge_base_assembly/).
COPY packaging/build_assets/lib/*.so /usr/local/lib/

# ---- Now drop the heavy build-only deps so the image stays slim ------------
# Note: this PURGES libsqlite3-dev which owns the libsqlite3.so symlink —
# we recreate it manually in the next step.
RUN apt-get remove -y --purge gcc libc6-dev libsqlite3-dev libssl-dev make luarocks \
    && apt-get autoremove -y --purge \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /root/.cache

# Restore the libsqlite3.so symlink (purged with libsqlite3-dev above).
# ffi.load("sqlite3") -> dlopen("libsqlite3.so") needs the unversioned name.
RUN ln -sf libsqlite3.so.0 /usr/lib/aarch64-linux-gnu/libsqlite3.so \
    && ldconfig

# ---- Bring in app code -----------------------------------------------------
# .dockerignore strips identity/, secrets/, var/, *.log, .git.
COPY robot_common /app/robot_common
COPY vendor       /app/vendor
COPY server       /app/server
COPY farm_soil    /app/farm_soil
COPY rancho_water /app/rancho_water

# ---- Container init + router config + supervisor ---------------------------
COPY packaging/container/start.sh     /app/start.sh
COPY packaging/container/zenohd.json5 /etc/zenohd.json5
RUN chmod +x /app/start.sh

# ---- Sane defaults (overridable by `docker run -e ...`) --------------------
ENV APP_DIR=/app \
    FLEET_DATA_DIR=/var/fleet \
    FLEET_SECRETS_DIR=/secrets \
    GATEWAY_HOST=127.0.0.1 \
    GATEWAY_PORT=8080 \
    ZENOH_LOCATOR=tcp/127.0.0.1:7447

# tini handles PID 1 + signal forwarding for the supervisor.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
