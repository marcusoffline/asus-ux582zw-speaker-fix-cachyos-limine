# ASUS Zenbook Pro Duo 15 OLED (UX582ZW) — Linux internal speaker fix

Make the **internal speakers work on Linux** on the ASUS Zenbook Pro Duo 15 OLED
**UX582ZW**. Out of the box the internal speakers are silent — only Bluetooth,
HDMI, and the 3.5 mm headphone jack produce sound — even though the exact same
speakers work fine on Windows.

This repo gives you two ways to fix it:

- **[Run one script](#option-a--run-the-script)** (with safety checks), or
- **[Follow the steps manually](#option-b--do-it-manually)** if you'd rather understand and apply each change yourself.

It also explains **[why](#background--why-the-speakers-are-silent)** it happens, so you can trust what you're running on your own machine.

> **Applies to:** ASUS Zenbook Pro Duo 15 OLED **UX582ZW** (Realtek ALC294 codec,
> two Cirrus Logic **CS35L41** amplifiers, ACPI `_SUB` `10431A8F`, audio subsystem
> id `1043:1a8f`). Tested on **Ubuntu 24.04** with kernel **6.17**. Very close
> siblings (e.g. UX582ZS/other CS35L41 Zenbooks) may work with `--force`, but the
> GPIO/boost values here are chosen for the UX582ZW.

---

## TL;DR

1. **Disable Secure Boot** in your UEFI/BIOS ([why](#step-0-disable-secure-boot-required)).
2. Run:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/CodingButter/asus-ux582zw-speaker-fix/main/install.sh | sudo bash
   ```
3. **Reboot.** Speakers work.

> Piping a script into `sudo bash` means trusting it. It's short and commented —
> please skim [`install.sh`](install.sh) first, or clone the repo and run it locally.
> You can also do a no-changes dry run: `... | sudo bash -s -- --check`.

---

## Is this you?

You have a UX582ZW and:

- 🔇 Internal speakers are completely silent on Linux.
- 🎧 Bluetooth headphones, HDMI audio, and the wired headphone jack **do** work.
- 🪟 The speakers work on Windows, so the hardware is fine.
- 🧾 `sudo dmesg | grep -i cs35l41` shows:

  ```
  cs35l41-hda ...: Failed property cirrus,dev-index: -22
  cs35l41-hda ...: error -EINVAL: Platform not supported
  ```

If so, this fix is for you. Confirm your machine is a match without changing anything:

```bash
sudo ./install.sh --check      # or: curl -fsSL <raw-url> | sudo bash -s -- --check
```

---

## Step 0: Disable Secure Boot (required)

The fix works by loading a small custom **ACPI table (SSDT)** from the initramfs.
When **Secure Boot** is on, the Linux kernel runs in *lockdown* mode and
**silently ignores** ACPI table overrides — so the fix would appear to do nothing.

Disable Secure Boot first:

1. Reboot and tap **F2** (or **Del**) at the ASUS logo to enter the UEFI/BIOS.
2. Go to the **Security** (or **Boot**) tab → **Secure Boot** / **Secure Boot Control** → set to **Disabled**.
3. **Save & Exit** (F10).

Verify from Linux afterwards:

```bash
mokutil --sb-state           # -> "SecureBoot disabled"
cat /sys/kernel/security/lockdown   # -> [none] ...
```

Disabling Secure Boot is safe for a normal personal machine; you can re-enable it
later if you switch to a kernel that supports this model natively.

---

## Option A — run the script

Clone and run (recommended so you can read it first):

```bash
git clone https://github.com/CodingButter/asus-ux582zw-speaker-fix
cd asus-ux582zw-speaker-fix
sudo ./install.sh            # apply the fix
```

Or the one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/CodingButter/asus-ux582zw-speaker-fix/main/install.sh | sudo bash
```

What the script does (idempotent — safe to run more than once):

| Step | Action |
|------|--------|
| Checks | Confirms model (`UX582ZW`), the CS35L41 amp (`CSC3551`), and that Secure Boot is off. Aborts with guidance if not. |
| Driver | Adds `snd_intel_dspcfg.dsp_driver=1` to `GRUB_CMDLINE_LINUX_DEFAULT` (forces the legacy HDA driver so the amp driver binds). |
| SSDT | Compiles the bundled SSDT with `iasl`, packages it into `/boot/acpi-cs35l41-ux582zw.cpio`. |
| GRUB | Loads that cpio early via `GRUB_EARLY_INITRD_LINUX_CUSTOM`, runs `update-grub`. |
| Backup | Every change to `/etc/default/grub` is backed up to `…/grub.bak.<timestamp>`. |

Flags: `--check` (checks only, no changes), `--uninstall` (undo), `--force` (skip the exact-model guard), `--help`.

Then **reboot** and [verify](#verify-it-worked).

---

## Option B — do it manually

If you'd rather apply each change by hand (identical to what the script does):

### 1. Force the legacy HDA driver

Edit `/etc/default/grub` and add `snd_intel_dspcfg.dsp_driver=1` to the kernel
command line:

```bash
sudo cp /etc/default/grub /etc/default/grub.bak
# GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
#                       ->  "quiet splash snd_intel_dspcfg.dsp_driver=1"
sudo sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 snd_intel_dspcfg.dsp_driver=1"/' /etc/default/grub
```

This makes the kernel use the classic `snd_hda_intel` path, under which the
`cs35l41-hda` amplifier driver attaches.

### 2. Create and compile the SSDT

Install the ACPI compiler and build [`ssdt-ux582zw-cs35l41.dsl`](ssdt-ux582zw-cs35l41.dsl):

```bash
sudo apt install -y acpica-tools
iasl -tc ssdt-ux582zw-cs35l41.dsl      # produces ssdt-ux582zw-cs35l41.aml
```

This SSDT injects the ACPI `_DSD` properties (amp indices, reset/chip-select
GPIOs, speaker positions, external-boost) that ASUS's firmware leaves out.

### 3. Package it into an early-load cpio

The kernel reads ACPI overrides from an **uncompressed** cpio, from the path
`kernel/firmware/acpi/`. Keep the filename ≤ 18 chars (kernel `MAX_CPIO_FILE_NAME`):

```bash
mkdir -p kernel/firmware/acpi
cp ssdt-ux582zw-cs35l41.aml kernel/firmware/acpi/cs35l41.aml
find kernel | cpio -H newc --create > acpi-cs35l41-ux582zw.cpio
sudo install -o root -g root -m 0644 acpi-cs35l41-ux582zw.cpio /boot/
```

### 4. Load it early via GRUB and regenerate

```bash
echo 'GRUB_EARLY_INITRD_LINUX_CUSTOM="acpi-cs35l41-ux582zw.cpio"' | sudo tee -a /etc/default/grub
sudo update-grub
```

### 5. Reboot

---

## Verify it worked

After rebooting:

```bash
# The amps should now initialize with ASUS's own tuning (not "Platform not supported"):
sudo dmesg | grep -i cs35l41
#   cs35l41-hda ...: Cirrus Logic CS35L41 (35a40), Revision: B2
#   cs35l41-hda ...: Firmware Loaded - Type: spk-prot, Gain: 17
#   cs35l41-hda ...: CS35L41 Bound - SSID: 10431A8F, ... CH: L, ...
#   cs35l41-hda ...: CS35L41 Bound - SSID: 10431A8F, ... CH: R, ...

# You should now have a Speaker output, and this should play a test tone:
wpctl status | grep -i speaker
speaker-test -c2 -twav -l1        # Ctrl+C to stop
```

If you also confirm the SSDT loaded:

```bash
sudo dmesg | grep -i 'Table Upgrade'
#   ACPI: Table Upgrade: install [SSDT-  CBTR- CS35L41]
```

---

## Uninstall / revert

```bash
sudo ./install.sh --uninstall
# then reboot
```

This removes the kernel parameter, the early-initrd entry, and the cpio, and
regenerates GRUB (a fresh `/etc/default/grub` backup is made first). It does
**not** re-enable Secure Boot — do that in your UEFI/BIOS if you want it back.

---

## Background — why the speakers are silent

The UX582ZW's internal speakers are driven by **two Cirrus Logic CS35L41 "smart
amp" chips** connected over SPI. On Linux the `cs35l41-hda` driver needs a set of
board-specific configuration values — amp indices, reset/interrupt/chip-select
GPIOs, speaker positions, and boost topology — normally provided by the firmware
as ACPI **`_DSD`** properties.

On this laptop ASUS ships the amp device (`\_SB.PC00.SPI1.SPK1`, `_HID "CSC3551"`,
`_SUB "10431A8F"`) with a valid `_CRS` (resources) but **no `_DSD` at all**, and
the model isn't in the kernel's built-in CS35L41 quirk tables. So the driver has
no idea how the amps are wired and gives up:

```
cs35l41-hda ...: Failed property cirrus,dev-index: -22
cs35l41-hda ...: error -EINVAL: Platform not supported
```

Meanwhile the Realtek ALC294 codec happily drives the speaker pin — but that
signal only reaches the (unpowered) amplifiers, so you hear nothing. Bluetooth
and HDMI bypass the amps entirely, which is why they work.

**The fix has two parts:**

1. **`snd_intel_dspcfg.dsp_driver=1`** — forces the legacy HDA driver so the
   `cs35l41-hda` amp driver attaches (under the default SOF driver it doesn't
   engage for this configuration).
2. **The SSDT** — supplies the missing `_DSD` so the driver can configure and
   power on the amps. The GPIO indices and property values are borrowed from the
   validated SSDT of the structurally identical **UX3405MA** (`_SUB 10431A63`),
   which has the same `_CRS` resource layout. No internal-boost current/inductor
   values are supplied, so the amps run in **external-boost** mode — the safe
   configuration for this hardware, and the reason the widely-cited "you could
   blow your speakers" warning about CS35L41 SSDT edits doesn't apply here.

Once configured, the driver even loads ASUS's own factory tuning for this model
(`cs35l41-dsp1-spk-prot-10431a8f-*`, already shipped in `linux-firmware`), which
includes proper speaker-protection limits.

---

## A note on sound quality

Even when working, the speakers sound **thinner / more bass-light than on
Windows**. That's expected and not a bug in this fix: Windows layers ASUS's audio
DSP (EQ + bass processing) on top, while Linux gets the raw amp output with only
the protection firmware, and these are physically small drivers. If it bothers
you, a software equalizer (e.g. **EasyEffects** with a bass-enhancer + a small cut
around 3 kHz) helps a lot — but that's optional and intentionally left out of this
fix, which is only about getting the speakers to make sound at all.

---

## Credits & references

Worked out by tracing the failure on a real UX582ZW and adapting the well-trodden
ASUS CS35L41 SSDT approach to this specific model.

- ASUS Linux — *No sound in 2023* (Cirrus amps guide): <https://asus-linux.org/guides/cirrus-amps/>
- lamperez — *CS35L41 amplifiers in an ASUS Zenbook on Linux*: <https://gist.github.com/lamperez/862763881c0e1c812392b5574727f6ff>
- smallcms/asus_zenbook_ux3405ma (structural SSDT reference): <https://github.com/smallcms/asus_zenbook_ux3405ma>
- Kernel docs — ACPI table override via initrd: <https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html>

## License

[MIT](LICENSE)
