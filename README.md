# surface-howdy

Passwordless `sudo` via **facial recognition** (Howdy) on **linux-surface** laptops with the Intel IPU3 camera (e.g. Surface Book 2 / Surface Pro 5/6 class hardware with `ov5693` front sensor).

The catch: the IPU3 camera is not a plain V4L2 device — it needs the libcamera
pipeline (`ipu3-cio2` raw bayer nodes + `ipu3-imgu` processing), which Howdy's
OpenCV/ffmpeg capture backends cannot consume directly. This project bridges
libcamera into a virtual V4L2 device that Howdy can read, and makes the camera
**on-demand**: it is woken for the ~3 seconds of each face check and shut down
immediately after — it does *not* run in the background.

```
┌──────────────┐   libcamera    ┌────────────────┐  v4l2loopback  ┌──────────┐
│ ov5693 front │ ─────────────► │ ipu3-imgu NV12 │ ─────────────► │/dev/video20│
│   sensor     │  (GStreamer    │  (processed)   │  (+180° rot,   │  Howdy     │
└──────────────┘  libcamerasrc) └────────────────┘   kernel-side)  └──────────┘
        ▲                                                        │
        │ systemctl --user restart/stop (on demand)              │
        └────────────── /lib/security/howdy/pam.py ◄─────────────┘
                              ▲
                        PAM: sudo (sufficient, password fallback)
```

## How a `sudo` authentication works

1. PAM invokes Howdy's `pam.py` (`auth sufficient pam_python3.so ...`).
2. `pam.py` starts the per-user bridge unit (`systemctl --user --machine=...`)
   and waits until the bridge owns `/dev/video20` (+1.5 s libcamera warm-up).
3. `compare.py` matches the live stream against your enrolled models.
4. `pam.py` **stops** the bridge again — camera LED off.
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

Tested on Omarchy 4.5 (Arch) with libcamera 0.7.2, GStreamer 1.28,
v4l2loopback 0.15.4, howdy 2.6.1, Python 3.14.

## Install

```bash
git clone https://github.com/<you>/surface-howdy.git
cd surface-howdy
sudo ./install.sh          # detects the front camera automatically
sudo howdy add             # enroll your face (2–3 passes, different lighting)
sudo -k && sudo -v         # test
```

The installer:
- auto-detects the front camera via `gst-device-monitor-1.0` (`api.libcamera.location = front`)
- writes `/etc/howdy-camera-bridge.conf` (camera identity + device)
- installs the loopback module options, udev rule, bridge script and a
  **user** systemd unit (`~/.config/systemd/user/howdy-camera-bridge.service`)
- installs the patched `pam.py` (kept as `pam.py.bak.<timestamp>`)
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
- **Very dark rooms**: dlib's HOG detector needs to actually *see* a face.
  The installer raises `dark_threshold` to `90` so dim frames aren't skipped,
  but if the sensor is starved (as on this test machine) the scan times out
  and you fall back to the password after a few seconds. Tune `timeout` /
  `certainty` in `sudo howdy config` to taste, or enroll extra models in the
  lighting conditions you actually unlock in.

## Tuning

Edit `/usr/lib/security/howdy/config.ini` (or `sudo howdy config`):

| key | default | notes |
|-----|---------|-------|
| `timeout` | 6 | seconds to scan before falling back to password |
| `certainty` | 3.5 | lower = stricter matching |
| `dark_threshold` | 90 | skip frames darker than this % (raised from 50 for low light) |
| `no_confirmation` | false | set `true` for silent success |

Add more models for different lighting: `sudo howdy add` (repeat).

Useful:
```bash
systemctl --user start howdy-camera-bridge    # manual camera-on
systemctl --user stop howdy-camera-bridge     # manual camera-off
sudo howdy test                               # live preview window
sudo howdy list                               # enrolled models
journalctl -t "[HOWDY]"                       # auth log
```

## Notes & caveats

- **Password fallback is always preserved.** If the face check fails, times
  out or the camera is unavailable, you get the normal password prompt.
- **SSH sessions**: `ignore_ssh = true` skips the face check remotely (password
  fallback applies).
- **While the bridge runs** the camera is exclusively held by libcamera —
  other apps (browser, Meet) can't open it during those ~3 s per auth. Stop
  the unit manually for video calls if you hit the window (`systemctl --user
  stop howdy-camera-bridge`).
- The PAM line is `sufficient`, so removing/reordering it can never lock you
  out of sudo; backups of every modified file are kept next to the original.
- `pam.py` is a derivative of Howdy (AGPL-3.0-or-later); the rest of the repo
  is MIT-licensed (see `LICENSE`).

## License

- `howdy/pam.py`: AGPL-3.0-or-later (derived work from [howdy](https://github.com/boltgolt/howdy))
- everything else: MIT
