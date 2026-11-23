# surface-howdy

Passwordless `sudo` via **facial recognition** (Howdy) on **linux-surface** laptops with the Intel IPU3 camera (e.g. Surface Book 2 / Surface Pro 5/6 class hardware).

The catch: the IPU3 cameras are not plain V4L2 devices — Howdy's OpenCV/ffmpeg
capture backends cannot consume them directly. This project bridges the
hardware into a virtual V4L2 device that Howdy can read, and makes the camera
**on-demand**: it is woken for the ~3 seconds of each face check and shut down
immediately after — it does *not* run in the background.

Two camera modes are supported (chosen at install time, default **IR**):

```
─────  IR mode (default, works in complete darkness)  ─────────────────────

┌──────────────┐  media-ctl     ┌──────────────┐  v4l2-ctl   ┌─────────────────────┐
│ ov7251 front │  raw IPU3 path │ ipu3-cio2    │  mmap Y10   │ unpack → GREY →     │
│   IR camera  │ ─────────────► │ /dev/video12 │ ──────────► │ ffmpeg (v4l2 OUTPUT)│
└──────────────┘  (link is off  └──────────────┘    (FIFO)   └─────────┬───────────┘
      ▲               by default)                                      │ v4l2loopback
      │ 850 nm flood emitter, driven by the sensor's STROBE pad         ▼
      │  (patched ov7251 module, see kernel-patches/)            ┌────────────┐
      └──────────────────────────────────────────────────────────│/dev/video20│
                                                                 └──────┬─────┘
─────  RGB mode (visible-light front camera)                            │
                                                                        ▼
┌──────────────┐   libcamera    ┌────────────────┐               ┌──────────┐
│ ov5693 front │ ─────────────► │ ipu3-imgu NV12 │ ────────────► │  Howdy   │
│   sensor     │  (GStreamer    │  (processed)   │  (+180° rot,  └────┬─────┘
└──────────────┘  libcamerasrc) └────────────────┘   kernel-side)     │
                                                                     ▼
                 systemctl --user restart/stop (on demand) ◄─────────┘
                                       ▲
                                 PAM: sudo (sufficient, password fallback)
```

## Camera modes: IR vs RGB

The installer asks which camera to use. What each mode actually does and
what you get:

| | **1) Front IR (ov7251)** — default | **2) Front RGB (ov5693)** | **3) Back RGB (ov8865)** |
|---|---|---|---|
| Pipeline | raw IPU3 CIO2 path (`/dev/video12`, Y10→GREY), driven by `howdy-camera-ir-setup.sh` + `howdy-camera-ir-bridge.sh` | libcamera via GStreamer (`libcamerasrc ! v4l2sink`), `howdy-camera-bridge.sh` | same as front RGB |
| Illumination | sensor's own **STROBE pad** drives the 850 nm flood emitter (patched `ov7251` kernel module) — works in **complete darkness** | ambient light only | ambient light only |
| Low-light behavior | unaffected; every frame is lit | dlib/YuNet can miss faces in dim rooms → password fallback | same, plus worse framing |
| Spoof resistance | better: a printed photo looks dark/noisy to an IR flood | weaker: ordinary visible-light photo can work | weaker |
| Extra requirements | `kernel-patches/` module rebuild **after every kernel update**; sudoers `NOPASSWD` rule for the installing user and the one root helper script; user in `video` group | none beyond the base deps | none |
| Camera in libcamera? | no — the ov7251's CSI-2 link is disabled by default; the setup helper enables it on demand and turns it off again | yes (`\_SB_.PCI0.I2C2.CAMF`) | yes (`\_SB_.PCI0.I2C3.CAMR`) |
| Notes | closest to Windows Hello | lighting-dependent accuracy | awkward angle while typing; has autofocus (irrelevant here) |

**Recommendation:** take mode 1 (IR). It's why Windows Hello feels magic —
the machine literally shines IR on your face, so unlock works with the
lights off. The only recurring cost is rebuilding the patched `ov7251`
module after kernel updates (one command, see `kernel-patches/`).

## How a `sudo` authentication works

1. PAM invokes Howdy's `pam.py` (`auth sufficient pam_python3.so ...`).
2. `pam.py` starts the per-user bridge unit (`systemctl --user --machine=...`)
   and waits until the bridge owns `/dev/video20` (plus a short pipeline
   warm-up: ~3 s in IR mode, ~1.5 s in RGB mode).
3. `compare.py` matches the live stream against your enrolled models
   (YuNet face detection when available — needed for IR frames).
4. `pam.py` **stops** the bridge again — IR mode additionally disables the
   sensor link and strobe via the root helper, camera LED off.
5. Success → authenticated. Failure → password fallback via `system-auth`.

Subsequent `sudo` calls within the 5-minute timestamp window don't re-trigger
the camera at all.

## Why kernel-side rotation?

The front sensor is mounted upside down (`api.libcamera.rotation = 180`).
Every userspace flip path tried here was broken in practice (GStreamer's
`videoflip` no-ops or corrupts the libcamera DMABUF buffers). Instead the
v4l2loopback module is loaded with `output_formats="mspace:2"`, which swaps
NV12↔NV21 on the capture side — a byte-level 180° rotation for free, in the
kernel, with zero CPU cost.

## Requirements

- linux-surface (or any distro with IPU3 libcamera pipeline support)
- `libcamera`, `pipewire-libcamera`, `v4l-utils`, `python` ≥ 3.10
- AUR: `howdy`, `python-dlib`, `pam-python-git`, `v4l2loopback-dkms`
- repo: `gst-plugins-good` (for `v4l2sink`), `ffmpeg`, `python-opencv` deps
- **IR mode only:** build the patched `ov7251` module from `kernel-patches/`
  (run its build script once, and again after each kernel update — the
  stock driver leaves the strobe pad disabled, so the IR flood stays dark)
- **RGB mode only:** `gst-plugins-good` (that's the `v4l2sink` element)

Tested on Omarchy 4.5 (Arch) with libcamera 0.7.2, GStreamer 1.28,
v4l2loopback 0.15.4, howdy 2.6.1, Python 3.14.

## Install

```bash
git clone https://github.com/<you>/surface-howdy.git
cd surface-howdy
sudo ./install.sh          # pick 1 = IR (default), 2/3 = RGB front/back
sudo howdy-enroll          # enroll your face — bridge-aware wrapper
                           # (plain `sudo howdy add` races with the PAM
                           #   bridge lifecycle and finds the camera idle)
sudo -k && sudo -v         # test
```

The installer:
- offers the camera menu (see table above), default IR
- writes `/etc/howdy-camera-bridge.conf` (`BRIDGE_MODE` + camera identity)
- installs the loopback module options, udev rule, bridge script(s) and a
  **user** systemd unit (`~/.config/systemd/user/howdy-camera-bridge.service`)
- IR mode: installs the root setup helper + a sudoers `NOPASSWD` rule for the installing user
  limited to exactly that script, and adds your user to the `video` group
- installs the patched `pam.py` (backup kept) and the YuNet face detector
  (`yunet.onnx`, downloaded once — dlib's HOG never fires on IR frames)
- points Howdy's `device_path` at `/dev/video20` (config backup kept)
- adds the Howdy line to `/etc/pam.d/sudo` **before** `system-auth`
  (face first, password fallback — backup kept)

## Uninstall

```bash
sudo ./uninstall.sh        # restores all backups, removes unit + configs
```

## Lock screen (after sleep)

The Omarchy lock screen (`omarchy-shell lock`) validates against the PAM
service `omarchy-lock-password`. `install.sh` wires the same Howdy line in
there, so waking from sleep and typing-unlock first attempts a face check
(camera on ~3 s, then off again) and falls back to the password.

Notes:
- Omarchy may rewrite `/etc/pam.d/omarchy-lock-password` on updates — if the
  face check disappears after an update, re-run `sudo ./install.sh`.
- **Very dark rooms**: in RGB mode dlib/YuNet must actually *see* your face.
  The installer raises `dark_threshold` to `90` so dim frames aren't skipped,
  but a starved RGB sensor times out and you fall back to the password.
  Switching to IR mode (default) sidesteps this entirely — the flood emitter
  lights your face regardless of room light. In RGB mode, tune `timeout` /
  `certainty` in `sudo howdy config` to taste, or enroll extra models in the
  lighting conditions you actually unlock in.

## Tuning

**Per-user settings** live in `~/.config/howdy/config.ini` — no root needed.
Values override the system config for *your* face checks only (sudo + lock
screen). The installer drops a starter file:

```ini
[video]
dark_threshold = 90   # low-light rooms: don't discard dim frames (1-100)
# certainty = 3.5     # matching strictness (lower = stricter)
# timeout = 6         # seconds to scan before password fallback
```

System-wide settings remain in `/usr/lib/security/howdy/config.ini`
(`sudo howdy config`):

| key | default | notes |
|-----|---------|-------|
| `timeout` | 6 | seconds to scan before falling back to password |
| `certainty` | 3.5 | lower = stricter matching |
| `dark_threshold` | 90 | skip frames darker than this % (raised from 50 for low light) |
| `no_confirmation` | false | set `true` for silent success |

Add more models for different lighting: `sudo howdy add` (repeat).

Useful:
```bash
systemctl --user start howdy-camera-bridge    # manual camera-on (both modes)
systemctl --user stop howdy-camera-bridge     # manual camera-off
sudo howdy-enroll                             # bridge-aware face enrollment
sudo howdy test                               # live preview window
sudo howdy list                               # enrolled models
journalctl -t "[HOWDY]"                       # auth log
sudo scripts/camera-probe.sh                  # full camera-stack inventory
sudo scripts/camera-test.sh ir                # raw IR capture sanity check
tail "${XDG_RUNTIME_DIR:-$HOME/.cache}/howdy-bridge.log"  # IR bridge lifecycle log
```

The active mode lives in `/etc/howdy-camera-bridge.conf` (`BRIDGE_MODE=ir|rgb`
plus `CAMERA_NAME` for RGB). Re-running `sudo ./install.sh` lets you switch;
switching between modes re-installs the matching bridge script and unit.

## Notes & caveats

- **Password fallback is always preserved.** If the face check fails, times
  out or the camera is unavailable, you get the normal password prompt.
- **SSH sessions**: `ignore_ssh = true` skips the face check remotely (password
  fallback applies).
- **While the bridge runs** the camera is exclusively held — other apps
  (browser, Meet) can't open it during those ~3 s per auth. Stop the unit
  manually for video calls if you hit the window (`systemctl --user stop
  howdy-camera-bridge`).
- **IR mode:** the front RGB camera (`ov5693`) stays fully free for normal
  use (video calls etc.) — authentication only ever touches the IR sensor.
- The PAM line is `sufficient`, so removing/reordering it can never lock you
  out of sudo; backups of every modified file are kept next to the original.
- `pam.py` is a derivative of Howdy (AGPL-3.0-or-later); the rest of the repo
  is MIT-licensed (see `LICENSE`).

## License

- `howdy/pam.py`: AGPL-3.0-or-later (derived work from [howdy](https://github.com/boltgolt/howdy))
- everything else: MIT
