#!/usr/bin/env bash
# Build and install the ov7251 kernel module with IR strobe support.
#
# Backport of Antoine Pichot's series "[PATCH v3 0/9] media: i2c: ov7251:
# fixes and infrared strobe for Surface Book 2" (Lore 20261113024059.1087031)
# to the running 7.2.15-arch1-1-surface kernel:
#   patch 1: in-range PLL1 dividers for the 319.2 MHz link
#   patch 2: link frequency index fix
#   patch 7: common registers moved into the global init table
#   patch 8: V4L2_CID_FLASH_STROBE_OE - the sensor's STROBE pad drives the
#            850 nm IR flood emitter directly (alternating lit/dark frames)
# Local adaptation: PERCENT macro defined (not in 7.2.y headers); the strobe
# control registration adapted to this kernel's smaller control handler.
#
# ov7251.c here is the patched source; re-run after every kernel update.
set -euo pipefail

cd "$(dirname "$0")"
KVER=$(uname -r)
KDIR=/lib/modules/$KVER/build
[ -d "$KDIR" ] || { echo "kernel headers for $KVER missing" >&2; exit 1; }

WORK=$(mktemp -d /tmp/ov7251-build.XXXXXX)
cp ov7251.c Makefile "$WORK/"
make -C "$KDIR" M="$WORK" modules

MOD=/lib/modules/$KVER/kernel/drivers/media/i2c/ov7251.ko.zst
sudo cp -a "$MOD" "$MOD.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
sudo rm -f "$MOD"
sudo cp "$WORK/ov7251.ko" "/lib/modules/$KVER/kernel/drivers/media/i2c/ov7251.ko"
sudo depmod -a

echo "Installed for $KVER. Reload the module (sensor must be unbound):"
echo "  echo i2c-INT347E:00 | sudo tee /sys/bus/i2c/drivers/ov7251/unbind"
echo "  sudo modprobe -r ov7251 && sudo modprobe ov7251"
echo "Or simply reboot."
