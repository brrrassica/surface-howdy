#!/bin/sh
# IR camera bridge (runs as your user, on demand via PAM):
#  1. asks the root helper to enable the ov7251 raw path (sudoers rule
#     limits NOPASSWD to that one script)
#  2. streams /dev/video12 (ip3y 10-bit) via v4l2-ctl mmap capture into a
#     FIFO; howdy-camera-ir-stream.py unpacks it to GREY and writes the
#     v4l2loopback device (/dev/video20) that Howdy reads
#  3. disables the sensor link again on exit so the camera is fully off
#     between authentications
set -u

SETUP=/usr/local/bin/howdy-camera-ir-setup.sh
STREAM=/usr/local/bin/howdy-camera-ir-stream.py
CAP=/dev/video12
LOOP=/dev/video20
LOG_DIR="${XDG_RUNTIME_DIR:-${HOME}/.cache}"
LOG="$LOG_DIR/howdy-bridge.log"
mkdir -p "$LOG_DIR"
# Refuse to write through a pre-created symlink in a shared location.
[ -L "$LOG" ] && rm -f "$LOG"

# Setup can transiently fail (EBUSY while a previous run's cleanup
# still holds the device): retry a few times before giving up.
ok=0
for _ in 1 2 3 4 5; do
	if sudo -n "$SETUP" on; then
		ok=1
		break
	fi
	sleep 1
done
if [ "$ok" != 1 ]; then
	echo "bridge: setup on failed" >> "$LOG"
	exit 1
fi
echo "bridge: started $$ $(date +%T)" >> "$LOG"

FIFO=$(mktemp -u /tmp/howdy-ir.XXXXXX.fifo)
mkfifo "$FIFO"

PRODUCER=""

cleanup() {
	# The trap is installed before PRODUCER is assigned; guard against an
	# unbound variable under set -u for early exits/signals.
	[ -n "$PRODUCER" ] && {
		kill "$PRODUCER" 2>/dev/null
		wait "$PRODUCER" 2>/dev/null
	}
	rm -f "$FIFO"
	sudo -n "$SETUP" off 2>/dev/null
	echo "bridge: cleaned up $$ $(date +%T)" >> "$LOG"
}
trap cleanup EXIT INT TERM

# Producer: mmap capture from the CIO2 node (it has no read() support),
# endless stream into the FIFO until killed.
v4l2-ctl -d "$CAP" --stream-mmap --stream-skip=3 \
	--stream-count=1000000000 --stream-to="$FIFO" &
PRODUCER=$!

# Unpacker -> ffmpeg (proper V4L2 OUTPUT streaming into the loopback)
"$STREAM" "$FIFO" | ffmpeg -hide_banner -loglevel error \
	-f rawvideo -pixel_format nv12 -video_size 640x480 -framerate 30 \
	-i pipe:0 -f v4l2 "$LOOP"
