#!/usr/bin/env bash
# Install passwordless (face-based) sudo via Howdy on linux-surface (Intel IPU3).
#
# What it does:
#   1. Installs required packages (repo + AUR)
#   2. Detects the libcamera front camera
#   3. Installs loopback kernel-module config, udev rule, bridge script + user unit
#   4. Installs the Python-3 PAM module (on-demand camera bridge) into Howdy
#   5. Wires Howdy into /etc/pam.d/sudo (face first, password fallback)
#
# After install: run `sudo howdy add` to enroll your face, then test with
# `sudo -k && sudo -v`.
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi

REAL_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo '')}"
[ -n "$REAL_USER" ] || { echo "Cannot determine invoking user (SUDO_USER)."; exit 1; }
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)

echo ">> User: $REAL_USER ($REAL_HOME)"

# ---------------------------------------------------------------- packages
echo ">> Installing packages..."
pacman -Q howdy &>/dev/null || omarchy pkg aur add howdy || {
	echo "howdy not installed; install it (AUR) plus python-dlib and re-run." >&2
	exit 1
}
pacman -Q pam-python-git &>/dev/null || omarchy pkg aur add pam-python-git
pacman -Q v4l2loopback-dkms &>/dev/null || omarchy pkg aur add v4l2loopback-dkms
pacman -Q gst-plugins-good &>/dev/null || pacman -S --noconfirm --needed gst-plugins-good

# ------------------------------------------------- detect the front camera
echo ">> Detecting libcamera front camera..."
# cam -l output:
#   1: Internal back camera (\_SB_.PCI0.I2C3.CAMR)
#   2: Internal front camera (\_SB_.PCI0.I2C2.CAMF)
# Extract the ID inside the parentheses of the front camera line.
CAM_PATH=$(cam -l 2>/dev/null | awk '
	/Internal front camera/ {
		match($0, /\(.+\)/)
		print substr($0, RSTART+1, RLENGTH-2)
		exit
	}')
if [ -z "$CAM_PATH" ]; then
	echo "Could not auto-detect the front camera. Available cameras:"
	cam -l 2>/dev/null || true
	read -r -p "Enter the front camera libcamera ID from the list above (e.g. \\_SB_.PCI0.I2C2.CAMF, NOT the leading number): " CAM_PATH
fi
# gst-launch property syntax eats one level of backslashes -> double them
CAM_ESC=$(printf '%s' "$CAM_PATH" | sed 's/\\/\\\\/g')
echo ">> Front camera: $CAM_PATH (escaped: $CAM_ESC)"

# ------------------------------------------------------------- /etc config
echo ">> Installing loopback module config..."
install -Dm644 "$REPO_DIR/etc/modules-load.d/v4l2loopback.conf" /etc/modules-load.d/v4l2loopback.conf
install -Dm644 "$REPO_DIR/etc/modprobe.d/v4l2loopback.conf"     /etc/modprobe.d/v4l2loopback.conf
install -Dm644 "$REPO_DIR/etc/udev/rules.d/99-howdy-loopback.rules" /etc/udev/rules.d/99-howdy-loopback.rules

cat > /etc/howdy-camera-bridge.conf <<EOF
# libcamera name of the camera to feed to Howdy (from: cam -l)
CAMERA_NAME='$CAM_ESC'
# v4l2loopback device howdy reads (see modprobe.d options above)
DEVICE=/dev/video20
EOF

modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback
udevadm control --reload
udevadm trigger /dev/video20 2>/dev/null || true
sleep 1
[ -e /dev/video20 ] || { echo "/dev/video20 missing after modprobe" >&2; exit 1; }

# ------------------------------------------------- bridge script + user unit
echo ">> Installing bridge script and user unit..."
install -Dm755 "$REPO_DIR/bridge/howdy-camera-bridge.sh" /usr/local/bin/howdy-camera-bridge.sh
install -d -m755 "$REAL_HOME/.config/systemd/user"
install -m644 "$REPO_DIR/systemd/user/howdy-camera-bridge.service" \
	"$REAL_HOME/.config/systemd/user/howdy-camera-bridge.service"
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config/systemd/user"

# Deliberately NOT enabled: pam.py starts/stops the unit on demand.
systemctl --user --machine="$REAL_USER@.host" daemon-reload

# --------------------------------------------------------- howdy pam module
echo ">> Installing Python-3 PAM module (backup of previous version kept)..."
cp -a /usr/lib/security/howdy/pam.py "/usr/lib/security/howdy/pam.py.bak.$TS"
install -m644 "$REPO_DIR/howdy/pam.py" /usr/lib/security/howdy/pam.py

# compare.py: add support for a per-user override config (HOWDY_USER_CONFIG)
cp -a /usr/lib/security/howdy/compare.py "/usr/lib/security/howdy/compare.py.bak.$TS"
install -m644 "$REPO_DIR/howdy/compare.py" /usr/lib/security/howdy/compare.py

# Default per-user override file (the whole point: user-settable settings
# like dark_threshold without touching root-owned files)
if [ ! -f "$REAL_HOME/.config/howdy/config.ini" ]; then
	install -d -m755 "$REAL_HOME/.config/howdy"
	install -m644 "$REPO_DIR/howdy/user-config.example.ini" \
		"$REAL_HOME/.config/howdy/config.ini"
	chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config/howdy"
fi

# The lock screen (omarchy-shell) runs PAM as the *user*, so Howdy's
# resources must be readable by non-root. dlib encodings are not
# reversible to images.
echo ">> Loosening Howdy file permissions for user-context PAM (lock screen)..."
chmod 755 /usr/lib/security/howdy/cli /usr/lib/security/howdy/recorders \
	/usr/lib/security/howdy/dlib-data /usr/lib/security/howdy/models \
	/usr/lib/security/howdy/pam-config /usr/lib/security/howdy/snapshots
chmod 644 /usr/lib/security/howdy/config.ini /usr/lib/security/howdy/compare.py \
	/usr/lib/security/howdy/snapshot.py \
	/usr/lib/security/howdy/logo.png /usr/lib/security/howdy/recorders/*.py \
	/usr/lib/security/howdy/cli/*.py /usr/lib/security/howdy/models/*.dat \
	/usr/lib/security/howdy/dlib-data/*.dat
chmod 1777 /usr/lib/security/howdy/snapshots
# cli.py must stay executable: /usr/bin/howdy is a symlink to it, and a
# non-executable target makes `sudo howdy` fail with "command not found"
chmod 755 /usr/lib/security/howdy/cli.py
rm -rf /usr/lib/security/howdy/__pycache__ /usr/lib/security/howdy/cli/__pycache__ \
	/usr/lib/security/howdy/recorders/__pycache__

# Low-light rooms: raise the dark-frame skip threshold so scans don't
# discard every frame (was 50; 90 keeps only near-black frames filtered).
sed -i 's|^dark_threshold = .*|dark_threshold = 90|' /usr/lib/security/howdy/config.ini

echo ">> Pointing howdy at the loopback device..."
cp -a /usr/lib/security/howdy/config.ini "/usr/lib/security/howdy/config.ini.bak.$TS"
sed -i 's|^device_path = .*|device_path = /dev/video20|' /usr/lib/security/howdy/config.ini

# --------------------------------------------------------------- sudo PAM
echo ">> Wiring Howdy into /etc/pam.d/sudo (face first, password fallback)..."
cp -a /etc/pam.d/sudo "/etc/pam.d/sudo.bak.$TS"
LINE='auth\t\tsufficient\tpam_python3.so /lib/security/howdy/pam.py'
if ! grep -q 'howdy/pam.py' /etc/pam.d/sudo; then
	python3 - "$LINE" <<'PY'
import sys
from pathlib import Path
line = sys.argv[1].replace('\\t', '\t')
p = Path('/etc/pam.d/sudo')
text = p.read_text()
if text.startswith('#%PAM-1.0'):
    parts = text.split('\n', 1)
    new = parts[0] + '\n' + line + (parts[1] if len(parts) > 1 else '')
else:
    new = line + text
p.write_text(new)
PY
fi

# --------------------------------------------------------------- lock screen
echo ">> Wiring Howdy into /etc/pam.d/omarchy-lock-password (screen unlock)..."
cp -a /etc/pam.d/omarchy-lock-password "/etc/pam.d/omarchy-lock-password.bak.$TS"
LOCK_LINE='auth       sufficient                  pam_python3.so /lib/security/howdy/pam.py'
if ! grep -q 'howdy/pam.py' /etc/pam.d/omarchy-lock-password; then
	python3 - "$LOCK_LINE" <<'PY'
import sys
from pathlib import Path
line = sys.argv[1].replace('\\t', '\t')
p = Path('/etc/pam.d/omarchy-lock-password')
text = p.read_text()
if text.startswith('#%PAM-1.0'):
    parts = text.split('\n', 1)
    new = parts[0] + '\n' + line + (parts[1] if len(parts) > 1 else '')
else:
    new = line + text
p.write_text(new)
PY
fi

cat <<'EOF'

=======================================================================
Installed. Next steps:

  1. Enroll your face (look at the camera, good lighting):
        sudo howdy add
     (repeat 2-3x in different lighting for better match rates)

  2. Test:
        sudo -k && sudo -v
        Lock the screen (omarchy system lock) and unlock with your face.

  3. Recovery (if anything breaks, as root):
        cp -a /etc/pam.d/sudo.bak.* /etc/pam.d/sudo   # newest backup
        cp -a /etc/pam.d/omarchy-lock-password.bak.* /etc/pam.d/omarchy-lock-password

The camera is started only for the duration of each face check and
stopped right after - it is not running in the background.
=======================================================================
EOF
