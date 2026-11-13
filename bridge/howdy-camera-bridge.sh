#!/bin/sh
# Howdy camera bridge: feeds the IPU3 front camera (via libcamera) into a
# v4l2loopback device that Howdy can read.
#
# The loopback module applies the 180-degree rotation the upside-down
# mounted sensor needs via output_formats="mspace:2" (NV12 -> NV21 swap),
# so no broken userspace flip filter is required.
#
# Camera identity and device are configured in /etc/howdy-camera-bridge.conf

CONF="${CONF:-/etc/howdy-camera-bridge.conf}"
[ -f "$CONF" ] && . "$CONF"

DEVICE="${DEVICE:-/dev/video20}"
: "${CAMERA_NAME:?CAMERA_NAME not set in $CONF}"

exec gst-launch-1.0 libcamerasrc camera-name="$CAMERA_NAME" ! videoconvert ! v4l2sink device="$DEVICE" sync=false
