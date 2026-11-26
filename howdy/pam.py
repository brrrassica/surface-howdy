# /lib/security/howdy/pam.py - Python 3 port of the packaged (Python 2)
# howdy 2.6.1 PAM interface, extended with an on-demand camera bridge:
# the libcamera -> v4l2loopback bridge (/dev/video20) is started just
# before the face check and stopped right after, so the camera is only
# active during actual authentication.
#
# NOTES:
#  * `pamh` is provided by pam-python as an argument to each pam_sm_*
#    function; do NOT import it at module level.
#  * howdy 2.6.1 does not ship a `utils` package - read the config with
#    configparser directly.
#  * `__file__` is unreliable inside pam-python, so the howdy directory
#    is hardcoded below (matches the Arch/AUR package layout).
#
# This file is derived from howdy (https://github.com/boltgolt/howdy),
# which is licensed AGPL-3.0-or-later.

import os
import glob
import syslog
import subprocess
import pwd

import configparser

HOWDY_DIR = '/usr/lib/security/howdy'
DEVICE = '/dev/video20'
BRIDGE_UNIT = 'howdy-camera-bridge.service'

# Read config from disk (__file__ is unreliable inside pam-python)
config = configparser.ConfigParser()
config.read(HOWDY_DIR + "/config.ini")


def _systemctl(user, action):
	"""Start/stop the user's camera bridge. Works when called as root
	(machine interface) and when called as the user (plain --user)."""
	cmds = [
		['systemctl', '--user', '--machine={}@.host'.format(user), action, BRIDGE_UNIT],
		['systemctl', '--user', action, BRIDGE_UNIT],
	]
	for cmd in cmds:
		try:
			r = subprocess.run(cmd, check=False, timeout=10)
			if r.returncode == 0:
				return
		except Exception:
			pass


def start_bridge(user):
	"""Wake the camera bridge and wait until it owns the device"""
	_systemctl(user, 'restart')
	for _ in range(12):
		try:
			if subprocess.run(['fuser', DEVICE],
					capture_output=True, timeout=2).returncode == 0:
				break
		except Exception:
			pass
		subprocess.run(['sleep', '0.3'], timeout=2)
	# Give the bridge pipeline (producer -> unpacker -> ffmpeg -> loopback)
	# time to emit its first stable frames
	subprocess.run(['sleep', '3'], timeout=5)


def stop_bridge(user):
	"""Release the camera immediately after authentication finished"""
	_systemctl(user, 'stop')


def doAuth(pamh):
	"""Starts authentication in a separate process"""

	# Abort if Howdy is disabled
	if config.getboolean("core", "disabled"):
		return pamh.PAM_AUTHINFO_UNAVAIL

	# Abort if we're in a remote SSH env
	if config.getboolean("core", "ignore_ssh"):
		if "SSH_CONNECTION" in os.environ or "SSH_CLIENT" in os.environ or "SSHD_OPTS" in os.environ:
			return pamh.PAM_AUTHINFO_UNAVAIL

	# Abort if lid is closed
	if config.getboolean("core", "ignore_closed_lid"):
		if any("closed" in open(f).read() for f in glob.glob("/proc/acpi/button/lid/*/state")):
			return pamh.PAM_AUTHINFO_UNAVAIL

	# Set up syslog
	syslog.openlog("[HOWDY]", 0, syslog.LOG_AUTH)

	# Alert the user that we are doing face detection
	if config.getboolean("core", "detection_notice"):
		pamh.conversation(pamh.Message(pamh.PAM_TEXT_INFO, "Attempting face detection"))

	user = pamh.get_user()
	syslog.syslog(syslog.LOG_INFO, "Attempting facial authentication for user " + user)

	# Wake the camera bridge only for the duration of the check
	start_bridge(user)

	try:
		# Run compare as a python3 subprocess to circumvent python version
		# and import issues. compare.py takes the username as argv[1] and
		# parses no flags.
		env = os.environ.copy()
		env['PAMPY_SCRIPT'] = 'True'
		# Per-user override config (dark_threshold etc.), if the user has one
		try:
			home = pwd.getpwnam(user).pw_dir
			env['HOWDY_USER_CONFIG'] = os.path.join(home, '.config', 'howdy', 'config.ini')
		except KeyError:
			pass
		status = subprocess.call(
			["/usr/bin/python3", HOWDY_DIR + "/compare.py", user], env=env)
	finally:
		# Always release the camera again
		stop_bridge(user)

	# Status 10 means we couldn't find any face models
	if status == 10:
		if not config.getboolean("core", "suppress_unknown"):
			pamh.conversation(pamh.Message(pamh.PAM_ERROR_MSG, "No face model known"))

		syslog.syslog(syslog.LOG_NOTICE, "Failure, no face model known")
		syslog.closelog()
		return pamh.PAM_USER_UNKNOWN

	# Status 14 means the face model exists but could not be read/parsed
	elif status == 14:
		if not config.getboolean("core", "suppress_unknown"):
			pamh.conversation(pamh.Message(pamh.PAM_ERROR_MSG, "Corrupt face model, please run: sudo howdy add"))

		syslog.syslog(syslog.LOG_ERR, "Failure, corrupt face model for user " + user)
		syslog.closelog()
		return pamh.PAM_SYSTEM_ERR

	# Status 11 means we exceeded the maximum retry count
	elif status == 11:
		pamh.conversation(pamh.Message(pamh.PAM_ERROR_MSG, "Face detection timeout reached"))
		syslog.syslog(syslog.LOG_INFO, "Failure, timeout reached")
		syslog.closelog()
		return pamh.PAM_AUTH_ERR

	# Status 12 means we aborted
	elif status == 12:
		syslog.syslog(syslog.LOG_INFO, "Failure, general abort")
		syslog.closelog()
		return pamh.PAM_AUTH_ERR

	# Status 13 means the image was too dark
	elif status == 13:
		syslog.syslog(syslog.LOG_INFO, "Failure, image too dark")
		syslog.closelog()
		pamh.conversation(pamh.Message(pamh.PAM_ERROR_MSG, "Face detection image too dark"))
		return pamh.PAM_AUTH_ERR
	# Status 0 is a successful exit
	elif status == 0:
		# Show the success message if it isn't suppressed
		if not config.getboolean("core", "no_confirmation"):
			pamh.conversation(pamh.Message(pamh.PAM_TEXT_INFO, "Identified face as " + user))

		syslog.syslog(syslog.LOG_INFO, "Login approved")
		syslog.closelog()
		return pamh.PAM_SUCCESS

	# Otherwise, we can't describe what happened but it wasn't successful
	pamh.conversation(pamh.Message(pamh.PAM_ERROR_MSG, "Unknown error: " + str(status)))
	syslog.syslog(syslog.LOG_INFO, "Failure, unknown error " + str(status))
	syslog.closelog()
	return pamh.PAM_SYSTEM_ERR


def pam_sm_authenticate(pamh, flags, args):
	"""Called by PAM when the user wants to authenticate, in sudo for example"""
	return doAuth(pamh)


def pam_sm_open_session(pamh, flags, args):
	"""No separate face scan on session open; the auth stack already gated it.
	(Avoids running the camera twice per sudo.)"""
	return pamh.PAM_SUCCESS


def pam_sm_close_session(pamh, flags, argv):
	"""We don't need to clean anything up at the end of a session"""
	return pamh.PAM_SUCCESS


def pam_sm_setcred(pamh, flags, argv):
	"""We don't need to set any credentials, so returns success"""
	return pamh.PAM_SUCCESS
