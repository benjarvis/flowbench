#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Ben Jarvis
# SPDX-License-Identifier: LGPL-2.1-only
#
# Configure a mlx5 NIC for io_uring ZCRX and run a flowbench server/client.
#
# Tested layout: Mellanox ConnectX-7, Ubuntu 26.04, kernel 7.0, mlx5 driver.
# Requires root.
#
# Usage:
#   sudo ETH=enp65s0np0 ZQ=62 NQ=1 PORT=12345 ./zcrx-setup.sh prep
#   sudo ETH=enp65s0np0 ZQ=62 NQ=1 PORT=12345 ./zcrx-setup.sh server
#   sudo ETH=enp65s0np0 ZQ=62 NQ=1 PORT=12345 ./zcrx-setup.sh client <server-ip>
#   sudo ETH=enp65s0np0 ZQ=62 NQ=1 PORT=12345 ./zcrx-setup.sh status
#   sudo ETH=enp65s0np0 ZQ=62 NQ=1 PORT=12345 ./zcrx-setup.sh teardown
#
# Variables:
#   ETH   interface name                       (required)
#   ZQ    base RX queue index for ZCRX         (required, e.g. 62)
#   NQ    number of contiguous queues          (default 1)
#   PORT  TCP port the server listens on       (default 12345)
#
set -euo pipefail

ETH=${ETH:?set ETH=<ifname>}
ZQ=${ZQ:?set ZQ=<base rxq>}
NQ=${NQ:-1}
PORT=${PORT:-12345}

ZQ_HI=$((ZQ + NQ - 1))

FLOWBENCH=${FLOWBENCH:-build/release/src/flowbench}

log() { printf '[zcrx] %s\n' "$*"; }

prep() {
    log "ETH=$ETH ZQ=$ZQ NQ=$NQ (queues $ZQ..$ZQ_HI) PORT=$PORT"

    # mlx5 ZCRX prerequisites: HW-GRO and tcp-data-split (HDS) must be on.
    # HW-GRO is a hard requirement for HDS to actually split headers.
    log "enable rx-gro-hw"
    ethtool -K "$ETH" rx-gro-hw on

    log "enable tcp-data-split"
    # Newer ethtool exposes this via ring params; older paths varied.
    if ethtool -g "$ETH" 2>/dev/null | grep -qi 'tcp-data-split'; then
        ethtool -G "$ETH" tcp-data-split on || true
    else
        log "  (no tcp-data-split knob in ethtool -G output — assuming driver default is fine)"
    fi

    log "enable ntuple flow steering"
    ethtool -K "$ETH" ntuple on

    # Carve the ZCRX queue out of the default RSS indirection table so the
    # only traffic that lands on it comes from explicit flow steering rules
    # we add below. After this:
    #   - default RSS context covers queues 0..ZQ-1
    #   - a new RSS context (id printed) covers queues ZQ..ZQ_HI; this
    #     context is what our ntuple rule will target.
    log "shrink default RSS to queues 0..$((ZQ - 1))"
    ethtool -X "$ETH" equal "$ZQ"

    log "create dedicated RSS context for queues $ZQ..$ZQ_HI"
    RSS_CTX=$(ethtool -X "$ETH" context new start "$ZQ" equal "$NQ" 2>&1 | tee /dev/stderr | awk '/New RSS context is/ {print $5}')
    if [ -z "${RSS_CTX:-}" ]; then
        log "WARN: could not parse RSS context id; check 'ethtool -x $ETH context <id>' manually"
    else
        log "new RSS context id = $RSS_CTX"
        echo "$RSS_CTX" > "/tmp/zcrx-rss-ctx-$ETH"
    fi

    log "steer TCP dst-port $PORT to queue $ZQ"
    # Single-queue: steer straight to the queue.
    # Multi-queue: steer to the RSS context so the NIC hashes within ZQ..ZQ_HI.
    if [ "$NQ" = "1" ]; then
        ethtool -N "$ETH" flow-type tcp4 dst-port "$PORT" action "$ZQ"
    else
        ethtool -N "$ETH" flow-type tcp4 dst-port "$PORT" context "$RSS_CTX"
    fi

    log "prep complete"
}

status() {
    log "==== link ===="
    ethtool "$ETH" | grep -E 'Speed|Link detected' || true
    log "==== features ===="
    ethtool -k "$ETH" | grep -E 'rx-gro-hw|ntuple-filters|tcp-segmentation-offload' || true
    log "==== ring (HDS) ===="
    ethtool -g "$ETH" | grep -iE 'tcp-data-split|HDS' || true
    log "==== RSS default ===="
    ethtool -x "$ETH" | head -20
    if [ -f "/tmp/zcrx-rss-ctx-$ETH" ]; then
        RSS_CTX=$(cat "/tmp/zcrx-rss-ctx-$ETH")
        log "==== RSS context $RSS_CTX ===="
        ethtool -x "$ETH" context "$RSS_CTX" | head -10
    fi
    log "==== ntuple rules ===="
    ethtool -n "$ETH" || true
    log "==== per-queue counters (busy queues only) ===="
    ethtool -S "$ETH" 2>/dev/null | grep -E "rx${ZQ}_|rx_queue_${ZQ}_" | grep -vE ': 0$' || true
}

teardown() {
    log "remove ntuple rules"
    ethtool -n "$ETH" 2>/dev/null | awk '/^Filter:/ {print $2}' | while read -r id; do
        ethtool -N "$ETH" delete "$id" || true
    done

    if [ -f "/tmp/zcrx-rss-ctx-$ETH" ]; then
        RSS_CTX=$(cat "/tmp/zcrx-rss-ctx-$ETH")
        log "delete RSS context $RSS_CTX"
        ethtool -X "$ETH" context "$RSS_CTX" delete || true
        rm -f "/tmp/zcrx-rss-ctx-$ETH"
    fi

    log "restore default RSS over all queues"
    ethtool -X "$ETH" default || ethtool -X "$ETH" equal "$(ethtool -l "$ETH" | awk '/Combined:/ {print $2; exit}')" || true

    log "teardown complete (rx-gro-hw / ntuple / tcp-data-split left as-is)"
}

server() {
    [ -x "$FLOWBENCH" ] || { echo "flowbench binary not found at $FLOWBENCH"; exit 1; }
    export EVPL_ZCRX=on
    export EVPL_ZCRX_INTERFACE="$ETH"
    export EVPL_ZCRX_RXQ="$ZQ"
    export EVPL_ZCRX_RXQ_COUNT="$NQ"
    log "EVPL_ZCRX=on  EVPL_ZCRX_INTERFACE=$ETH  EVPL_ZCRX_RXQ=$ZQ  EVPL_ZCRX_RXQ_COUNT=$NQ"
    log "running: flowbench -r server -p io_uring_tcp -l 0.0.0.0:$PORT $*"
    # flowbench: -l = local listen addr:port; -P = num_threads (NOT port).
    exec "$FLOWBENCH" -r server -p io_uring_tcp -l "0.0.0.0:$PORT" "$@"
}

client() {
    SERVER_IP=${1:?usage: $0 client <server-ip>}
    shift || true
    [ -x "$FLOWBENCH" ] || { echo "flowbench binary not found at $FLOWBENCH"; exit 1; }
    log "running: flowbench -r client -p io_uring_tcp -a $SERVER_IP:$PORT $*"
    # flowbench: -a = peer addr:port (where to connect); -P = num_threads.
    exec "$FLOWBENCH" -r client -p io_uring_tcp -a "$SERVER_IP:$PORT" "$@"
}

case "${1:-}" in
    prep)      shift; prep      "$@" ;;
    status)    shift; status    "$@" ;;
    teardown)  shift; teardown  "$@" ;;
    server)    shift; server    "$@" ;;
    client)    shift; client    "$@" ;;
    *) echo "usage: $0 {prep|server|client|status|teardown}"; exit 1 ;;
esac
