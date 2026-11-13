# ov7251 IR strobe backport

Source: Antoine Pichot, "[PATCH v3 0/9] media: i2c: ov7251: fixes and
infrared strobe for Surface Book 2"
(https://patchew.org/linux/20261113024059.1087031-1-antoine.pichot@gmail.com/).

The OV7251 has a STROBE output pad that pulses during the exposure of
selected frames, meant to drive an illuminator. On Surface hardware the
front IR camera's 850 nm flood emitter is wired to that pin (ACPI exposes
no separate LED/GPIO for it). The stock driver leaves the pad disabled,
so the camera sees only ambient IR.

Applied patches (backported to the running 7.2.15-arch1-1-surface kernel):

1. In-range PLL1 dividers for the 319.2 MHz link (0x30B4=0x04, 0x30B1=0x01)
2. Link frequency index fix
7. Common registers moved into the global init table
8. `V4L2_CID_FLASH_STROBE_OE` control: STROBE pad output enable, alternate
   frame pattern (0xAA), pulse span follows exposure (52..776 lines, <=45%
   duty). Lit/dark frames alternate - Howdy's compare discards the dark
   ones via dark_threshold.

Local adaptations for the 7.2.y base: `PERCENT` macro defined locally,
the strobe control registered in this kernel's control-handler layout.

## Build and install (repeat after every kernel update)

    sudo ./build-ov7251-strobe.sh

Then reload the module (or reboot):

    echo i2c-INT347E:00 | sudo tee /sys/bus/i2c/drivers/ov7251/unbind
    sudo modprobe -r ov7251 && sudo modprobe ov7251

Verify: `v4l2-ctl -d /dev/v4l-subdev8 --list-ctrls | grep strobe`
(and with the strobe enabled, roughly every other captured frame is lit).

## Note

Patch 9 (ipu-bridge rotation quirk for Surface Book 2 / Pro 7+) was not
applied - not needed for this machine. Patches 3-6 (pixel rate, vblank
reset, active state, orientation controls) were skipped as unrelated to
the strobe feature; patch 7 applied cleanly, patches 1/2 fixed the
link-frequency table selection so the sensor streams cleanly.
