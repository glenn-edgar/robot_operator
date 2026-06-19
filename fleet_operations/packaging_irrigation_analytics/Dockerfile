# syntax=docker/dockerfile:1.6
#
# Single-container fleet image for the irrigation_analytics complex. Sibling
# image to nanodatacenter/fleet-mcfarland — coexists on the same Pi (different
# host ports per packaging_irrigation_analytics/wsl/start.sh).
#
# In-container procs (supervised by /app/start.sh under tini PID 1):
#   1. zenohd                         (router on 0.0.0.0:7447, internal)
#   2. server/fleet_manager           (registration RPC + 1 Hz heartbeat)
#   3. server/persistence             (Zenoh -> SQLite knowledge_base)
#   4. server/application_gateway     (HTTP -> persistence query RPC, dashboard)
#   5. server/notification_service    (Discord push; no-op without webhook)
#   6. irrigation_analytics robot     (lacima instance by default)
#
# Build from the fleet_design/ root via packaging_irrigation_analytics/build.sh.
# Target arch: linux/arm64 (Pi 4 + future Arduino Uno Q QRB2210 / Cortex-A53).
# Today native build runs on WSL arm64; same image deploys unchanged to Pi.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# ---- Add Eclipse zenoh APT repo --------------------------------------------
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
        openssh-client \
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
# Shared with packaging/build_assets/ — same .so files, same staging script
# (packaging_irrigation_analytics/build.sh delegates to packaging/build.sh's
# staging step then builds with this Dockerfile).
COPY packaging/build_assets/lib/*.so /usr/local/lib/

# ---- Drop heavy build-only deps so the image stays slim --------------------
# Note: openssh-client stays. controller_client.lua invokes
# `ssh pi@irrigation 'python3 -' < tmp_file` — python3 runs REMOTELY on the
# controller, not in this image; only the ssh client is needed locally.
RUN apt-get remove -y --purge gcc libc6-dev libsqlite3-dev libssl-dev make luarocks \
    && apt-get autoremove -y --purge \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /root/.cache

# Restore the libsqlite3.so symlink (purged with libsqlite3-dev above).
RUN ln -sf libsqlite3.so.0 /usr/lib/aarch64-linux-gnu/libsqlite3.so \
    && ldconfig

# ---- App code --------------------------------------------------------------
COPY robot_common /app/robot_common
COPY vendor       /app/vendor
COPY server       /app/server

# Only the fleet_design scaffold of irrigation_analytics gets baked in.
# robot/ (production bare-LuaJIT KB1/KB3 detector) runs OUTSIDE any container.
# explore/, tests/, docs/, var/, identity/, secrets/ are dev-host-only or
# bind-mounted at runtime.
COPY irrigation_analytics/chains          /app/irrigation_analytics/chains
COPY irrigation_analytics/lib             /app/irrigation_analytics/lib
COPY irrigation_analytics/main.lua        /app/irrigation_analytics/main.lua
COPY irrigation_analytics/class_spec.lua  /app/irrigation_analytics/class_spec.lua
COPY irrigation_analytics/run.sh          /app/irrigation_analytics/run.sh

# KB1 + KB3 reference data — bake into image. KB1/KB3 read-only at runtime;
# KB2/KB4 (when added) will need bind-mount + RW since they update baselines.
COPY irrigation_analytics/explore/kb1_thresholds.json         /app/irrigation_analytics/data/kb1_thresholds.json
COPY irrigation_analytics/explore/baseline_state/baselines.json /app/irrigation_analytics/data/baselines.json

# KB4 clog/leak detector — seed baselines + ETO valve membership list.
# kb4.db itself lives on the writable bind mount (/var/fleet/kb4/kb4.db);
# seed is used only on first boot when the runs/baselines tables are empty.
COPY irrigation_analytics/data/kb4_nonETO_baselines.json /app/irrigation_analytics/data/kb4_nonETO_baselines.json
COPY irrigation_analytics/data/kb4_ETO_baselines.json    /app/irrigation_analytics/data/kb4_ETO_baselines.json
COPY irrigation_analytics/data/eto_valves.json           /app/irrigation_analytics/data/eto_valves.json

# KB2 topology — per-valve branch + expected_coil_R for cohort analysis.
COPY irrigation_analytics/data/kb2_topology.json         /app/irrigation_analytics/data/kb2_topology.json

# ---- Container init + router config + supervisor ---------------------------
COPY packaging_irrigation_analytics/container/start.sh     /app/start.sh
COPY packaging_irrigation_analytics/container/zenohd.json5 /etc/zenohd.json5
RUN chmod +x /app/start.sh /app/irrigation_analytics/run.sh

# ---- Defaults (overridable by `docker run -e ...`) -------------------------
ENV APP_DIR=/app \
    FLEET_DATA_DIR=/var/fleet \
    FLEET_SECRETS_DIR=/secrets \
    GATEWAY_HOST=127.0.0.1 \
    GATEWAY_PORT=8080 \
    ZENOH_LOCATOR=tcp/127.0.0.1:7447 \
    IRRIGATION_ANALYTICS_INSTANCE=lacima

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/start.sh"]
