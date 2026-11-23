#!/usr/bin/env bash
# Install passwordless (face-based) sudo via Howdy on linux-surface (Intel IPU3).
#
# What it does:
#   1. Installs required packages (repo + AUR)
#   2. Camera selector (Back RGB / Front IR / Front RGB; IR via raw IPU3 path)
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

# ------------------------------------------------- camera selector
# Surface camera anatomy (see scripts/camera-probe.sh):
#   Back RGB   ov8865 (\_SB_.PCI0.I2C3.CAMR) - rear camera, has autofocus
#   Front IR   ov7251 (\_SB_.PCI0.I2C2, raw IPU3 path) - mono IR camera;
#              NOT registered with libcamera, fed via the raw CIO2 path.
#              Its STROBE pad drives the 850 nm flood emitter directly
#              (needs the patched ov7251 module from kernel-patches/).
#   Front RGB  ov5693 (\_SB_.PCI0.I2C2.CAMF) - user-facing camera
echo ">> Camera selection:"
cat <<'MENU'
  1) Front IR   (ov7251)  [default, recommended]
        Mono IR sensor, like Windows Hello. The 850 nm flood emitter is
        driven from the sensor's STROBE pad via the patched ov7251
        kernel module (see kernel-patches/ - run its build script once
        after each kernel update). Works in complete darkness.
  2) Front RGB  (ov5693)  - the user-facing camera
        WARNING: RGB face auth is lighting-dependent and generally less
        reliable than IR; expect more password fallbacks in dim rooms.
  3) Back RGB   (ov8865)  - the rear camera (has autofocus)
        WARNING: awkward angle (you cannot face it while typing), and
        RGB face auth is lighting-dependent and less reliable than IR.
MENU
printf 'Choose [1/2/3, default 1]: '
read -r CAM_CHOICE || CAM_CHOICE=1
CAM_CHOICE=${CAM_CHOICE:-1}
case "$CAM_CHOICE" in
	1) CAM_MODE=ir ;;
	2) CAM_MODE=rgb; CAMERA_NAME='\_SB_.PCI0.I2C2.CAMF' ;;
	3) CAM_MODE=rgb; CAMERA_NAME='\_SB_.PCI0.I2C3.CAMR' ;;
	*) echo "Invalid choice." >&2; exit 1 ;;
esac
if [ "$CAM_MODE" = rgb ]; then
	echo ">> WARNING: RGB authentication selected - accuracy is lighting-dependent"
	echo "   and lower than IR. Keep your password fallback handy."
	sleep 2
fi

cat > /etc/howdy-camera-bridge.conf <<EOF
# Camera feed mode for the Howdy loopback bridge (/dev/video20):
#   ir  - front IR camera (ov7251) via the raw IPU3 path (/dev/video12)
#   rgb - libcamera camera via gstreamer (libcamerasrc)
BRIDGE_MODE='$CAM_MODE'
EOF
if [ "$CAM_MODE" = rgb ]; then
	# gst-launch property syntax eats one level of backslashes -> double them
	CAM_ESC=$(printf '%s' "$CAMERA_NAME" | sed 's/\\/\\\\/g')
	echo "CAMERA_NAME='$CAM_ESC'" >> /etc/howdy-camera-bridge.conf
fi
echo ">> Selected mode: $CAM_MODE"

# ------------------------------------------------------------- /etc config
echo ">> Installing loopback module config..."
install -Dm644 "$REPO_DIR/etc/modules-load.d/v4l2loopback.conf" /etc/modules-load.d/v4l2loopback.conf
install -Dm644 "$REPO_DIR/etc/modprobe.d/v4l2loopback.conf"     /etc/modprobe.d/v4l2loopback.conf
install -Dm644 "$REPO_DIR/etc/udev/rules.d/99-howdy-loopback.rules" /etc/udev/rules.d/99-howdy-loopback.rules

modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback
udevadm control --reload
udevadm trigger /dev/video20 2>/dev/null || true
sleep 1
[ -e /dev/video20 ] || { echo "/dev/video20 missing after modprobe" >&2; exit 1; }

# ------------------------------------------------- bridge script + user unit
echo ">> Installing bridge script and user unit..."
if [ "$CAM_MODE" = ir ]; then
	install -Dm755 "$REPO_DIR/bridge/howdy-camera-ir-bridge.sh" /usr/local/bin/howdy-camera-bridge.sh
	install -Dm755 "$REPO_DIR/bridge/howdy-camera-ir-setup.sh" /usr/local/bin/howdy-camera-ir-setup.sh
	install -Dm755 "$REPO_DIR/bridge/howdy-camera-ir-stream.py" /usr/local/bin/howdy-camera-ir-stream.py
	# The user-unit bridge needs to run the root setup helper without a
	# password prompt (PAM can't interact). Rule is limited to this script
	# and the installing user.
	install -d -m755 /etc/sudoers.d
	printf '%s ALL=(root) NOPASSWD: /usr/local/bin/howdy-camera-ir-setup.sh\n' "$REAL_USER" \
		> /etc/sudoers.d/howdy-camera-ir-setup
	chmod 440 /etc/sudoers.d/howdy-camera-ir-setup
	visudo -c -f /etc/sudoers.d/howdy-camera-ir-setup || {
		echo "sudoers validation failed; removing." >&2
		rm -f /etc/sudoers.d/howdy-camera-ir-setup
		exit 1
	}
	# The IR capture node /dev/video12 is root:video - make sure the user
	# can read it (takes effect on next login).
	id -nG "$REAL_USER" | grep -qw video || usermod -aG video "$REAL_USER"
else
	install -Dm755 "$REPO_DIR/bridge/howdy-camera-bridge.sh" /usr/local/bin/howdy-camera-bridge.sh
fi
install -d -m755 "$REAL_HOME/.config/systemd/user"
if [ "$CAM_MODE" = ir ]; then
	install -m644 "$REPO_DIR/systemd/user/howdy-camera-bridge-ir.service" \
		"$REAL_HOME/.config/systemd/user/howdy-camera-bridge.service"
else
	install -m644 "$REPO_DIR/systemd/user/howdy-camera-bridge.service" \
		"$REAL_HOME/.config/systemd/user/howdy-camera-bridge.service"
fi
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config/systemd/user"

# Deliberately NOT enabled: pam.py starts/stops the unit on demand.
systemctl --user --machine="$REAL_USER@.host" daemon-reload

# Enrollment wrapper: `sudo howdy add` alone can't work because the PAM
# sudo stack stops the bridge before the CLI captures. This script owns
# the bridge lifetime for the duration of the enrollment.
install -Dm755 "$REPO_DIR/bridge/howdy-enroll.sh" /usr/local/bin/howdy-enroll

# --------------------------------------------------------- howdy pam module
echo ">> Installing Python-3 PAM module (backup of previous version kept)..."
cp -a /usr/lib/security/howdy/pam.py "/usr/lib/security/howdy/pam.py.bak.$TS"
install -m644 "$REPO_DIR/howdy/pam.py" /usr/lib/security/howdy/pam.py

# compare.py: add support for a per-user override config (HOWDY_USER_CONFIG)
cp -a /usr/lib/security/howdy/compare.py "/usr/lib/security/howdy/compare.py.bak.$TS"
install -m644 "$REPO_DIR/howdy/compare.py" /usr/lib/security/howdy/compare.py

# YuNet face detector (fast DNN, works on IR frames where dlib fails)
install -m644 "$REPO_DIR/howdy/yunet_detector.py" /usr/lib/security/howdy/yunet_detector.py
if [ ! -f /usr/lib/security/howdy/dlib-data/yunet.onnx ]; then
	curl -sL "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx" \
		-o /usr/lib/security/howdy/dlib-data/yunet.onnx \
		&& chmod 644 /usr/lib/security/howdy/dlib-data/yunet.onnx \
		&& echo ">> Downloaded YuNet face detector model" \
		|| echo ">> WARNING: could not download yunet.onnx; falling back to dlib detectors" >&2
fi
chmod 644 /usr/lib/security/howdy/dlib-data/yunet.onnx 2>/dev/null || true

# cli/add.py: same YuNet preference for enrollment (file not vendored, patch inline)
ADD_PY=/usr/lib/security/howdy/cli/add.py
if [ -f "$ADD_PY" ] && ! grep -q yunet_detector "$ADD_PY"; then
	cp -a "$ADD_PY" "$ADD_PY.bak.$TS"
	python3 - "$ADD_PY" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """use_cnn = config.getboolean("core", "use_cnn", fallback=False)
if use_cnn:
	face_detector = dlib.cnn_face_detection_model_v1(path + "/../dlib-data/mmod_human_face_detector.dat")
else:
	face_detector = dlib.get_frontal_face_detector()"""
new = old + """

# Prefer the fast YuNet (OpenCV DNN) detector when available: dlib HOG
# never fires on IR frames and the CNN takes 20+ s per frame.
try:
	from yunet_detector import maybe_create
	yunet = maybe_create(path + "/..")
	if yunet is not None:
		face_detector = yunet
except Exception:
	pass"""
assert old in s, "add.py template changed"
s = s.replace(old, new)
old2 = "\tface_locations = face_detector(gsframe, 1)"
new2 = """\t# YuNet wants the raw color frame (CLAHE breaks it on IR frames)
\tif getattr(face_detector, "is_color", False):
\t\tface_locations = face_detector(frame, 1)
\telse:
\t\tface_locations = face_detector(gsframe, 1)"""
assert old2 in s, "add.py detection call changed"
s = s.replace(old2, new2)
open(p, 'w').write(s)
PY
	echo ">> Patched cli/add.py for YuNet detection"
fi

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
	/usr/lib/security/howdy/cli/*.py 2>/dev/null || true
chmod 644 /usr/lib/security/howdy/models/*.dat /usr/lib/security/howdy/dlib-data/*.dat 2>/dev/null || true
chmod 1777 /usr/lib/security/howdy/snapshots
# cli.py must stay executable: /usr/bin/howdy is a symlink to it, and a
# non-executable target makes `sudo howdy` fail with "command not found"
chmod 755 /usr/lib/security/howdy/cli.py
rm -rf /usr/lib/security/howdy/__pycache__ /usr/lib/security/howdy/cli/__pycache__ \
	/usr/lib/security/howdy/recorders/__pycache__

# Low-light handling depends on the feed: RGB frames are bright but noisy
# in dim rooms, IR strobe frames are well lit but the unilluminated
# background stays dark (~40% of pixels), so a high threshold tolerates
# that while still skipping genuinely unlit frames.
if [ "$CAM_MODE" = ir ]; then
	sed -i 's|^dark_threshold = .*|dark_threshold = 60|' /usr/lib/security/howdy/config.ini
	# dlib encodings on noisy IR frames (5-landmark predictor) have
	# intra-person distances around 0.5; the default 3.5 (0.35) can
	# never match. 7.0 still leaves impostor distances (0.75+) out.
	sed -i 's|^certainty = .*|certainty = 7.0|' /usr/lib/security/howdy/config.ini
	# The bridge pipeline needs a few seconds to warm up after the
	# on-demand start, so give the scan more than the default 6s.
	sed -i 's|^timeout = .*|timeout = 10|' /usr/lib/security/howdy/config.ini
else
	sed -i 's|^dark_threshold = .*|dark_threshold = 90|' /usr/lib/security/howdy/config.ini
fi

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

  1. Enroll your face - see the mode-specific NOTE below
     (IR: sudo howdy-enroll; RGB: sudo howdy add). Repeat 2-3x.

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

if [ "$CAM_MODE" = ir ]; then
	cat <<'EOF'

NOTE (IR mode):
  - Do NOT use plain `sudo howdy add` - the PAM sudo stack stops the
    camera bridge before the CLI can capture. Use the wrapper instead:
        sudo howdy-enroll        # repeat 2-3x, varied distance
  - If your session predates the install, the video-group membership
    added above needs a re-login to take effect.
  - RGB models may match poorly on IR frames: re-enroll fresh models
    for IR (sudo howdy clear, then sudo howdy-enroll).
EOF
fi
