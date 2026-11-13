#!/usr/bin/env bash
# camera-test.sh: live exercises for the hardware camera-probe.sh discovers.
#
# Subcommands:
#   ir    Stream the IR camera (ov7251) through the IPU3 raw path and save
#         frames as PNG. The ov7251 is normally NOT registered with libcamera
#         (its CSI-2 link is disabled), so this enables the link, configures
#         formats, captures raw Y8/Y10 from the CIO2 node, then restores the
#         link state.
#   af    Sweep the autofocus voice-coil motor (dw9719) across its range while
#         capturing frames from the rear (ov8865) camera through libcamera,
#         and rank each step by sharpness (cv2 Laplacian variance).
#   all   Run both.
#
# Both need root (media-ctl link changes, v4l2 subdev writes).
# Usage: sudo ./camera-test.sh [ir|af|all]
set -uo pipefail

OUTDIR=${OUTDIR:-/tmp/camtest}
IR_FRAMES=${IR_FRAMES:-30}
AF_FRAMES=${AF_FRAMES:-10}   # per focus step
AF_STEPS=${AF_STEPS:-9}      # 0..1023 sweep resolution

mkdir -p "$OUTDIR"

# ---------------------------------------------------------------- helpers
find_media() { # sensor name -> media dev
	for m in /dev/media*; do
		[ -c "$m" ] || continue
		media-ctl -d "$m" -p 2>/dev/null | grep -q "$1" && { echo "$m"; return 0; }
	done
	return 1
}

v4l_node_for_entity() { # entity name -> video node (CIO2 sink)
	media-ctl -d "$1" -p 2>/dev/null | awk -v ent="$2" '
		/^- entity/ { e=$0 }
		e ~ ("- entity .*" ent) && /device node name/ { print $NF; exit }'
}

# ------------------------------------------------------------ IR camera test
test_ir() {
	local MEDIA NODE SENSOR="ov7251"
	MEDIA=$(find_media "$SENSOR") || { echo "No $SENSOR in media topology." >&2; return 1; }
	NODE=$(v4l_node_for_entity "$MEDIA" "ipu3-cio2 2")
	[ -n "$NODE" ] || { echo "Cannot find CIO2 node for port 2." >&2; return 1; }
	echo ">> IR sensor: $SENSOR on $MEDIA, capture node: $NODE"

	local SENSOR_SUBDEV FULL
	SENSOR_SUBDEV=$(media-ctl -d "$MEDIA" -p | awk -v s="$SENSOR" '
		/^- entity/ { e=$0 } e~s && /device node name/ { print $NF; exit }')
	FULL=$(media-ctl -d "$MEDIA" -p | awk -v s="$SENSOR" '
		/^- entity/ { e=$0 } e~s && /device node name/ {
			sub(/^- entity [0-9]+: /, "", e); sub(/ \(.*$/, "", e); print e; exit }')
	echo ">> sensor subdev: $SENSOR_SUBDEV (entity: $FULL)"

	# remember whether the link was enabled, so we can restore it
	local WAS_ON
	WAS_ON=$(media-ctl -d "$MEDIA" -p | awk -v s="$SENSOR" '
		e_seen==0 && /^- entity/ { e="" }
		/^- entity/ { e=$0 }
		e~s && /-> "ipu3-csi2 2":0/ {
			if ($0 ~ /ENABLED/) print "yes"; else print "no"; exit
		}')
	echo ">> link currently ENABLED: ${WAS_ON:-unknown}"

	echo ">> enabling link and setting Y10 format..."
	media-ctl -d "$MEDIA" -l "\"$FULL\":0 -> \"ipu3-csi2 2\":0[1]" ||
		{ echo "Could not enable the sensor link." >&2; return 1; }
	PIX=Y10_1X10
	media-ctl -d "$MEDIA" -V "\"$FULL\":0[fmt:$PIX/640x480]"
	media-ctl -d "$MEDIA" -V "\"ipu3-csi2 2\":0[fmt:$PIX/640x480]"
	media-ctl -d "$MEDIA" -V "\"ipu3-csi2 2\":1[fmt:$PIX/640x480]"
	echo ">> sensor format: $PIX"

	# The CIO2 DMA node only outputs IPU3-packed 10-bit formats; use 'ip3y'
	# (V4L2_PIX_FMT_IPU3_Y10): 25 pixels per 32 bytes, LSB-first bitstream.
	local RAW="$OUTDIR/ir.raw"
	# max exposure/gain: the IR emitter is not driven (unbound ACPI device),
	# so without an external IR source we rely on ambient IR
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=exposure=1704 --set-ctrl=analogue_gain=1023
	v4l2-ctl -d "$NODE" --set-fmt-video=width=640,height=480,pixelformat=ip3y \
		--stream-mmap --stream-skip=5 --stream-count="$IR_FRAMES" --stream-to="$RAW" ||
		{ echo "Capture failed." >&2; return 1; }
	v4l2-ctl -d "$SENSOR_SUBDEV" --set-ctrl=exposure=504 --set-ctrl=analogue_gain=16

	echo ">> converting $IR_FRAMES frames to PNG and computing stats..."
	python3 - "$RAW" "$OUTDIR" <<'PY'
import sys, os
import numpy as np, cv2
raw, outdir = sys.argv[1], sys.argv[2]
w, h = 640, 480
stride = ((w * 10 + 7) // 8 + 31) // 32 * 32   # rows padded to 32 bytes (832)
valid = (w * 10 + 7) // 8                       # 800 bytes of pixel data
n = stride * h
data = open(raw, 'rb').read()
frames = [data[i:i+n] for i in range(0, len(data) - n + 1, n)]
out = []
for f in frames:
    arr = np.frombuffer(f, np.uint8).reshape(h, stride)
    ng = stride // 32                       # 32-byte groups per row
    gbits = np.unpackbits(arr, bitorder='little').reshape(h, ng, 256)
    gbits = gbits[:, :, :250]               # 25 pixels x 10 bits per group (6 pad bits)
    gbits = gbits.reshape(h, ng * 25, 10)[:, :w]
    vals = (gbits * (1 << np.arange(10, dtype=np.uint16))).sum(axis=2)
    # normalise 10-bit -> 8-bit for viewing
    out.append((vals >> 2).astype(np.uint8))
means = [f.mean() for f in out]
stds = [f.std() for f in out]
best = int(np.argmax(stds))
cv2.imwrite(os.path.join(outdir, 'ir_best.png'), out[best])
for i, f in enumerate(out[:3]):
    cv2.imwrite(os.path.join(outdir, f'ir_{i}.png'), f)
print(f'frames={len(out)} mean={np.mean(means):.1f} std={np.mean(stds):.1f}')
print(f'saved: {outdir}/ir_best.png (+ir_0..2.png)')
PY

	# restore link state
	if [ "$WAS_ON" = "no" ]; then
		echo ">> restoring disabled link state"
		media-ctl -d "$MEDIA" -l "\"$FULL\":0 -> \"ipu3-csi2 2\":0[0]"
	fi
	echo ">> note: the IR flood emitter (TPS68470/TPS61311 = INT3481) is not"
	echo "   exposed by this BIOS; frames rely on ambient IR."
}

# ------------------------------------------------------------ AF sweep test
test_af() {
	# find the VCM subdev exposing focus_absolute
	local VCM=""
	for d in /dev/v4l-subdev*; do
		[ -e "$d" ] || continue
		v4l2-ctl -d "$d" --list-ctrls 2>/dev/null | grep -q focus_absolute && { VCM="$d"; break; }
	done
	[ -n "$VCM" ] || { echo "No focus_absolute subdev found (no VCM bound)." >&2; return 1; }

	local MIN MAX
	MIN=$(v4l2-ctl -d "$VCM" --list-ctrls | grep focus_absolute | sed 's/[()]//g' | grep -o 'min=[0-9]*' | cut -d= -f2)
	MAX=$(v4l2-ctl -d "$VCM" --list-ctrls | grep focus_absolute | sed 's/[()]//g' | grep -o 'max=[0-9]*' | cut -d= -f2)
	echo ">> VCM at $VCM, range $MIN..$MAX"

	# rear camera (the VCM hangs off the ov8865 / INT347A module)
	local CAM_NAME
	CAM_NAME=$(cam -l 2>/dev/null | awk -F'[()]' '/Internal back camera/{gsub(/\\/,"\\\\"); print $2}')
	[ -n "$CAM_NAME" ] || { echo "Rear camera not registered with libcamera." >&2; return 1; }
	echo ">> rear camera: $CAM_NAME"
	local CAMIDX
	CAMIDX=$(cam -l 2>/dev/null | awk -F: '/Internal back camera/{gsub(/^ /,"",$1); print $1; exit}')

	local RESULTS="$OUTDIR/af-results.txt"
	: >"$RESULTS"
	local STEP=$(( (MAX - MIN) / AF_STEPS ))
	local i f
	local CAMIDX
	CAMIDX=$(cam -l 2>/dev/null | awk -F: '/Internal back camera/{gsub(/^ /,"",$1); print $1; exit}')
	for i in $(seq 0 $AF_STEPS); do
		f=$(( MIN + i * STEP )); [ $i -eq $AF_STEPS ] && f=$MAX
		v4l2-ctl -d "$VCM" --set-ctrl=focus_absolute="$f"
		sleep 0.5
		rm -rf "$OUTDIR/af_step"; mkdir -p "$OUTDIR/af_step"
		cam -c "$CAMIDX" "-C$AF_FRAMES" \
			-F"$OUTDIR/af_step/frame-#.bin" \
			-s role=viewfinder,width=1280,height=960 >/dev/null 2>&1 ||
			{ echo "   capture failed at focus=$f"; echo "$f -1" >>"$RESULTS"; continue; }
		local S
		S=$(python3 - "$OUTDIR/af_step" <<'PY'
import sys, glob, os
import numpy as np, cv2
W, H = 1280, 960
ysz = W * H
best = 0.0
for p in glob.glob(os.path.join(sys.argv[1], '*.bin')):
    sz = os.path.getsize(p)
    if sz < ysz:
        continue  # unexpected stream layout
    y = np.fromfile(p, np.uint8)[:ysz].reshape(H, W)  # NV12: Y plane first
    v = cv2.Laplacian(y, cv2.CV_64F).var()
    best = max(best, v)
print(f"{best:.1f}")
PY
)
		echo "focus=$f sharpness=$S" | tee -a "$RESULTS"
		python3 - "$OUTDIR/af_step" "$OUTDIR/af_focus_$f.png" <<'PY'
import sys, glob, os
import numpy as np, cv2
W, H, ysz = 1280, 960, 1280*960
best = (0.0, None)
for p in glob.glob(os.path.join(sys.argv[1], '*.bin')):
    y = np.fromfile(p, np.uint8)[:ysz].reshape(H, W)
    v = cv2.Laplacian(y, cv2.CV_64F).var()
    if v > best[0]:
        best = (v, y)
if best[1] is not None:
    cv2.imwrite(sys.argv[2], best[1])
PY
		rm -rf "$OUTDIR/af_step"
		v4l2-ctl -d "$VCM" --set-ctrl=focus_absolute=$(( (MIN+MAX)/2 ))
	done
	echo
	echo ">> results in $RESULTS (higher sharpness = better focus)"
}

# -------------------------------------------------------------------- main
case "${1:-all}" in
	ir) test_ir ;;
	af) test_af ;;
	all) test_ir && echo && test_af ;;
	*) echo "usage: $0 [ir|af|all]" >&2; exit 1 ;;
esac
