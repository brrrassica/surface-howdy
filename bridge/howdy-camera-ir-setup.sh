#!/bin/sh
# Root helper for the IR camera bridge (called with sudo -n by the user
# bridge script; a sudoers.d rule grants NOPASSWD for this file only).
#
#   howdy-camera-ir-setup.sh on   -> enable ov7251 link, Y10 formats, strobe
#   howdy-camera-ir-setup.sh off  -> disable link, restore default state
#
# The ov7251 IR camera is NOT registered with libcamera (its CSI-2 link is
# disabled by default), so the raw IPU3 path is configured here by hand:
#   ov7251 3-0060 -> ipu3-csi2 2 -> ipu3-cio2 2 (/dev/video12)
set -eu

MEDIA=/dev/media1
SENSOR='ov7251 3-0060'
CSI2='ipu3-csi2 2'
CIO2_NODE=/dev/video12
SENSOR_SUBDEV=/dev/v4l-subdev8

case "${1:-on}" in
on)
	# Kill stale producers from previous bridge runs: two v4l2-ctl
	# producers interleaving bytes in one FIFO corrupt every frame,
	# and leaked gst readers hold the loopback queue in a bad state.
	fuser -k /dev/video12 2>/dev/null || true
	fuser -k /dev/video20 2>/dev/null || true
	sleep 1
	media-ctl -d "$MEDIA" -l "\"$SENSOR\":0 -> \"$CSI2\":0[1]"
	media-ctl -d "$MEDIA" -V "\"$SENSOR\":0[fmt:Y10_1X10/640x480]"
	media-ctl -d "$MEDIA" -V "\"$CSI2\":0[fmt:Y10_1X10/640x480]"
	media-ctl -d "$MEDIA" -V "\"$CSI2\":1[fmt:Y10_1X10/640x480]"
	# Strobe illumination (requires the patched ov7251 module from
	# kernel-patches/: V4L2_CID_FLASH_STROBE_OE drives the 850 nm flood
	# emitter from the sensor's STROBE pad; lit and dark frames alternate).
	# Exposure must stay safely below the 488-line frame so the strobe
	# span (which follows the exposure) never straddles into the
	# neighbouring frame - that corrupts every lit frame. 400 is clean
	# in short bursts but corrupts over sustained streaming; 100 stays
	# clean for the full length of a capture and keeps faces detectable.
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=exposure=100
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=strobe_output_enable=1 \
		|| echo "warning: strobe_output_enable failed - unpatched ov7251 module? falling back to ambient IR" >&2
	v4l2-ctl -d "$CIO2_NODE" --set-fmt-video=width=640,height=480,pixelformat=ip3y
	;;
off)
	fuser -k /dev/video12 2>/dev/null || true
	fuser -k /dev/video20 2>/dev/null || true
	media-ctl -d "$MEDIA" -l "\"$SENSOR\":0 -> \"$CSI2\":0[0]" || true
	media-ctl -d "$MEDIA" -V "\"$SENSOR\":0[fmt:Y10_1X10/640x480]" || true
	media-ctl -d "$MEDIA" -V "\"$CSI2\":0[fmt:Y10_1X10/640x480]" || true
	media-ctl -d "$MEDIA" -V "\"$CSI2\":1[fmt:Y10_1X10/640x480]" || true
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=exposure=504 || true
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=strobe_output_enable=0 || true	;;
*)
	echo "usage: $0 [on|off]" >&2
	exit 1
	;;
esac
