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

sudo -n "$SETUP" on || exit 1

FIFO=$(mktemp -u /tmp/howdy-ir.XXXXXX.fifo)
mkfifo "$FIFO"

cleanup() {
	kill "$PRODUCER" 2>/dev/null
	wait "$PRODUCER" 2>/dev/null
	rm -f "$FIFO"
	sudo -n "$SETUP" off 2>/dev/null
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
