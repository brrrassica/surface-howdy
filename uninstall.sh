#!/usr/bin/env bash
# Uninstall the surface-howdy face-sudo setup and restore backups.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo." >&2
	exit 1
fi

REAL_USER="${SUDO_USER:-$(id -un 1000 2>/dev/null || echo '')}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ">> Stopping and removing the user bridge unit..."
systemctl --user --machine="$REAL_USER@.host" stop howdy-camera-bridge.service 2>/dev/null || true
rm -f "$REAL_HOME/.config/systemd/user/howdy-camera-bridge.service"
systemctl --user --machine="$REAL_USER@.host" daemon-reload 2>/dev/null || true
rm -f /usr/local/bin/howdy-camera-bridge.sh /etc/howdy-camera-bridge.conf
rm -f /usr/local/bin/howdy-camera-ir-bridge.sh /usr/local/bin/howdy-camera-ir-setup.sh \
	/usr/local/bin/howdy-camera-ir-stream.py
rm -f /etc/sudoers.d/howdy-camera-ir-setup

echo ">> Restoring /etc/pam.d/sudo from newest backup..."
BAK=$(ls -1t /etc/pam.d/sudo.bak.* 2>/dev/null | head -1 || true)
[ -n "$BAK" ] && cp -a "$BAK" /etc/pam.d/sudo && echo "   restored $BAK"

echo ">> Restoring /etc/pam.d/omarchy-lock-password from newest backup..."
BAK=$(ls -1t /etc/pam.d/omarchy-lock-password.bak.* 2>/dev/null | head -1 || true)
[ -n "$BAK" ] && cp -a "$BAK" /etc/pam.d/omarchy-lock-password && echo "   restored $BAK"

echo ">> Restoring howdy config.ini from newest backup..."
BAK=$(ls -1t /usr/lib/security/howdy/config.ini.bak.* 2>/dev/null | head -1 || true)
[ -n "$BAK" ] && cp -a "$BAK" /usr/lib/security/howdy/config.ini && echo "   restored $BAK"

echo ">> Restoring packaged pam.py (python2 original) if a backup exists..."
BAK=$(ls -1t /usr/lib/security/howdy/pam.py.bak.* 2>/dev/null | head -1 || true)
[ -n "$BAK" ] && cp -a "$BAK" /usr/lib/security/howdy/pam.py && echo "   restored $BAK"

echo ">> Removing kernel-module config and rule..."
rm -f /etc/modules-load.d/v4l2loopback.conf
rm -f /etc/modprobe.d/v4l2loopback.conf
rm -f /etc/udev/rules.d/99-howdy-loopback.rules
modprobe -r v4l2loopback 2>/dev/null || true
udevadm control --reload

echo "Done. howdy/pam-python packages remain installed; remove with:"
echo "  omarchy pkg drop howdy python-dlib pam-python-git v4l2loopback-dkms"
