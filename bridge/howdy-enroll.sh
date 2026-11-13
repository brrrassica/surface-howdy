#!/bin/sh
# Root enrollment helper: wraps `howdy add` with the camera bridge lifetime.
#
# Plain `sudo howdy add` cannot work on its own: the PAM sudo stack starts
# the bridge for the password/face prompt and stops it right after, so
# howdy's CLI then finds /dev/video20 idle. This wrapper runs the bridge
# only for the duration of the enrollment.
set -eu

REAL_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo '')}"
[ -n "$REAL_USER" ] || { echo "Cannot determine invoking user." >&2; exit 1; }

MACHINE=--machine="$REAL_USER@.host"
systemctl --user "$MACHINE" start howdy-camera-bridge.service

cleanup() {
	systemctl --user "$MACHINE" stop howdy-camera-bridge.service 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Bridge needs ~1.5s (libcamera warmup) before the first usable frames
sleep 2

howdy add "$@"
