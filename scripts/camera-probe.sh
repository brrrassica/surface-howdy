#!/usr/bin/env bash
# camera-probe.sh: read-only inventory of the camera stack (anatomy report).
#
# Shows what camera hardware exists and how it is wired up:
#   - libcamera-registered cameras
#   - V4L2 video nodes and subdevs (sensors, CSI-2, IMGU, lens/VCM actuators)
#   - media-ctl topologies
#   - I2C devices and bound drivers (sensors, VCM, emitters)
#   - relevant dmesg lines (root only)
#
# Usage: ./camera-probe.sh [output-file]      (default: print to stdout)
set -uo pipefail

OUT=${1:-/dev/stdout}
run() { echo "\$ $*" >&2; "$@" 2>&1; }

sec() {
	{
		echo
		echo "======================================================================="
		echo "== $*"
		echo "======================================================================="
	} >>"$OUT"
}

: >"$OUT"

sec "libcamera-registered cameras"
run cam -l >>"$OUT"

sec "V4L2 devices"
run v4l2-ctl --list-devices >>"$OUT"

sec "V4L2 subdevs: entities, formats and focus/AF controls"
for d in /dev/v4l-subdev*; do
	[ -e "$d" ] || continue
	echo "--- $d" >>"$OUT"
	# entity name for this subdev, if any
	for m in /dev/media*; do
		[ -c "$m" ] || continue
		entity=$(media-ctl -d "$m" -p 2>/dev/null | awk -v dev="$d" '
			/^- entity/ { ent=$0 }
			$0 ~ "device node name " dev { print ent; exit }')
		[ -n "$entity" ] && { echo "    entity: $entity"; break; }
	done
	v4l2-ctl -d "$d" --list-ctrls 2>/dev/null | grep -iE 'focus|af_|lens|exposure|gain|flip|blanking|test_pattern' \
		| sed 's/^/    ctrl: /'
	v4l2-ctl -d "$d" --list-ctrls-menus 2>/dev/null | grep -i test_pattern | sed 's/^/    menus: /'
done >>"$OUT"

sec "I2C devices and bound drivers"
# VCM sub-devices live at <HID>-VCM
for dev in /sys/bus/i2c/devices/*-VCM; do
	[ -e "$dev" ] || continue
	drv=$(readlink "$dev/driver" 2>/dev/null | xargs -r basename)
	printf '%-20s driver=%-10s (voice-coil motor / autofocus)\n' "$(basename "$dev")" "${drv:-UNBOUND}" >>"$OUT"
done
# bound devices only for the main table; unbound HID devices go in the next section
for dev in /sys/bus/i2c/devices/i2c-*:*; do
	[ -e "$dev" ] && [ -e "$dev/driver" ] || continue
	case "$(basename "$dev")" in *-VCM) continue ;; esac
	hid=$(basename "$dev")
	drv=$(readlink "$dev/driver" 2>/dev/null | xargs -r basename)
	mod=$(cat "$dev/modalias" 2>/dev/null)
	printf '%-20s driver=%-10s modalias=%s\n' "$hid" "${drv:-UNBOUND}" "${mod:-}" >>"$OUT"
done

sec "ACPI camera-emitter hints (unbound devices are candidates)"
for dev in /sys/bus/i2c/devices/i2c-*; do
	[ -e "$dev" ] || continue
	[ -e "$dev/driver" ] && continue
	case "$(basename "$dev")" in *-VCM) continue ;; esac
	printf 'UNBOUND: %s modalias=%s\n' "$(basename "$dev")" "$(cat "$dev/modalias" 2>/dev/null)" >>"$OUT"
done

for m in /dev/media*; do
	[ -c "$m" ] || continue
	sec "media topology: $m"
	media-ctl -d "$m" -p 2>&1 >>"$OUT"
done

if [ "$(id -u)" -eq 0 ]; then
	sec "dmesg: camera-relevant kernel messages"
	dmesg | grep -iE 'ipu3|cio2|ov5693|ov8865|ov7251|dw9719|dw9714|ad5820|vcm|libcamera|INT33BE|INT347A|INT347E|MSHW0125' >>"$OUT"
else
	sec "dmesg: skipped (not root; re-run with sudo for this section)"
fi

echo "Probe complete: $OUT"
echo
echo "Quick read:"
echo "  - cameras listed by 'cam -l' are usable through libcamera/gstreamer"
echo "  - 'UNBOUND' I2C devices are hardware that no kernel driver claimed"
echo "  - a sensor wired to ipu3-csi2 with a NON-ENABLED link (media topology)"
echo "    exists but is not registered with libcamera - see camera-test.sh ir"
