#!/usr/bin/env bash
#
# ASUS Zenbook Pro Duo 15 OLED (UX582ZW) - Linux internal speaker fix
# https://github.com/CodingButter/asus-ux582zw-speaker-fix
#
# Enables the two Cirrus Logic CS35L41 smart amplifiers that ASUS ships
# without ACPI _DSD configuration, by (1) forcing the legacy HDA audio
# driver and (2) injecting the missing _DSD via an SSDT ACPI override
# loaded from the initramfs.
#
#   sudo ./install.sh              apply the fix (default)
#   sudo ./install.sh --check      run all checks, change nothing
#   sudo ./install.sh --uninstall  undo the fix
#   sudo ./install.sh --force      skip the exact-model guard (close siblings)
#   sudo ./install.sh --help
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/CodingButter/asus-ux582zw-speaker-fix/main/install.sh | sudo bash
#
set -euo pipefail

# ---------------------------------------------------------------- constants ---
REPO_URL="https://github.com/CodingButter/asus-ux582zw-speaker-fix"
EXPECTED_BOARD="UX582ZW"
EXPECTED_SSID="1043:1a8f"          # ALC294 subsystem id on this machine
ACPI_HID="CSC3551"                 # Cirrus CS35L41 ACPI hardware id
KPARAM="snd_intel_dspcfg.dsp_driver=1"
CPIO_NAME="acpi-cs35l41-ux582zw.cpio"   # file in /boot
AML_MEMBER="cs35l41.aml"                # <=18 chars: kernel MAX_CPIO_FILE_NAME
GRUB_DEFAULT="/etc/default/grub"
BOOT_DIR="/boot"

MODE="install"
FORCE=0
WORK=""

# ------------------------------------------------------------------- output ---
if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_RST=""
fi
log()  { printf '%s==>%s %s\n'  "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '  %s+%s %s\n'  "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%sFAIL:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

usage() {
  cat <<EOF
${C_BLD}ASUS Zenbook Pro Duo UX582ZW - Linux speaker fix${C_RST}

  sudo ./install.sh              apply the fix (default)
  sudo ./install.sh --check      run checks only, make no changes
  sudo ./install.sh --uninstall  undo the fix
  sudo ./install.sh --force      skip the exact-model guard (close siblings)
  sudo ./install.sh --help       show this help

$REPO_URL
EOF
  exit 0
}

banner() {
  printf '%s\n'   "${C_BLD}ASUS Zenbook Pro Duo UX582ZW - Linux speaker fix${C_RST}"
  printf '%s\n\n' "$REPO_URL"
}

# --------------------------------------------------------- grub file helpers ---
# Read the contents of a GRUB_* "..."-quoted variable (empty if unset).
_get_var() { sed -nE "s/^$1=\"?([^\"]*)\"?.*/\1/p" "$GRUB_DEFAULT" | head -n1; }

# Set (or append) a GRUB_* variable to a quoted value.
_set_var() {
  local var="$1" val="$2"
  if grep -qE "^$var=" "$GRUB_DEFAULT"; then
    awk -v v="$var" -v val="$val" '$0 ~ "^" v "=" { print v "=\"" val "\""; next } { print }' \
      "$GRUB_DEFAULT" > "$GRUB_DEFAULT.tmp" && mv "$GRUB_DEFAULT.tmp" "$GRUB_DEFAULT"
  else
    printf '%s="%s"\n' "$var" "$val" >> "$GRUB_DEFAULT"
  fi
}

# Echo a space-separated token list with tokens matching any glob pattern removed.
_tokens_without() {
  local list="$1"; shift
  local out="" t pat drop
  for t in $list; do
    drop=0
    for pat in "$@"; do
      # shellcheck disable=SC2254
      case "$t" in $pat) drop=1;; esac
    done
    [ "$drop" -eq 0 ] && out="$out $t"
  done
  echo "$out" | xargs 2>/dev/null || true
}

backup_grub() {
  local ts bak
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)"
  bak="${GRUB_DEFAULT}.bak.${ts}"
  cp -a "$GRUB_DEFAULT" "$bak"
  ok "backed up $GRUB_DEFAULT -> $bak"
}

add_kernel_param() {
  local cur new
  cur="$(_get_var GRUB_CMDLINE_LINUX_DEFAULT)"
  case " $cur " in *" $KPARAM "*) ok "kernel param already set: $KPARAM"; return;; esac
  new="$(echo "$cur $KPARAM" | xargs)"
  _set_var GRUB_CMDLINE_LINUX_DEFAULT "$new"
  ok "added kernel param: $KPARAM"
}
remove_kernel_param() {
  local cur new
  cur="$(_get_var GRUB_CMDLINE_LINUX_DEFAULT)"
  new="$(_tokens_without "$cur" "$KPARAM")"
  _set_var GRUB_CMDLINE_LINUX_DEFAULT "$new"
  ok "removed kernel param: $KPARAM"
}
set_early_initrd() {
  local cur new
  cur="$(_get_var GRUB_EARLY_INITRD_LINUX_CUSTOM)"
  new="$(_tokens_without "$cur" '*cs35l41*' '*ux582*' "$CPIO_NAME")"
  new="$(echo "$new $CPIO_NAME" | xargs)"
  _set_var GRUB_EARLY_INITRD_LINUX_CUSTOM "$new"
  ok "early initrd set: $CPIO_NAME"
}
clear_early_initrd() {
  local cur new
  cur="$(_get_var GRUB_EARLY_INITRD_LINUX_CUSTOM)"
  new="$(_tokens_without "$cur" '*cs35l41*' '*ux582*' "$CPIO_NAME")"
  _set_var GRUB_EARLY_INITRD_LINUX_CUSTOM "$new"
  ok "removed our early-initrd entries"
}

regen_grub() {
  log "regenerating GRUB configuration ..."
  if command -v update-grub >/dev/null 2>&1; then
    update-grub 2>&1 | sed 's/^/    /'
  else
    local cfg="/boot/grub/grub.cfg"
    [ -f /boot/grub2/grub.cfg ] && cfg="/boot/grub2/grub.cfg"
    grub-mkconfig -o "$cfg" 2>&1 | sed 's/^/    /'
  fi
}

grub_cfg_path() { [ -f /boot/grub2/grub.cfg ] && echo /boot/grub2/grub.cfg || echo /boot/grub/grub.cfg; }

# ------------------------------------------------------------------- checks ---
# Each returns 0 (ok) or 1 (blocking). They print their own status.
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    warn "must run as root"
    return 1
  fi
  return 0
}

check_os() {
  if ! command -v update-grub >/dev/null 2>&1 && ! command -v grub-mkconfig >/dev/null 2>&1; then
    warn "GRUB not detected (no update-grub / grub-mkconfig)."
    printf '    This script targets GRUB systems. For systemd-boot, see the manual\n'
    printf '    method in the README (same SSDT, different early-initrd wiring).\n'
    return 1
  fi
  if [ ! -f "$GRUB_DEFAULT" ]; then
    warn "$GRUB_DEFAULT not found"
    return 1
  fi
  ok "GRUB configuration present"
  return 0
}

check_model() {
  local pn bn rc=0
  pn="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
  bn="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
  log "detected machine: ${pn:-unknown}  (board: ${bn:-unknown})"
  if printf '%s %s' "$pn" "$bn" | grep -q "$EXPECTED_BOARD"; then
    ok "model matches $EXPECTED_BOARD"
  elif [ "$FORCE" -eq 1 ]; then
    warn "model does not look like $EXPECTED_BOARD, but --force was given; continuing"
  else
    warn "this machine is not a $EXPECTED_BOARD (found: ${pn:-unknown})."
    printf '    If you have a very close CS35L41 sibling and know what you are doing,\n'
    printf '    re-run with --force. Otherwise this fix is not for your machine.\n'
    rc=1
  fi
  if ls -d /sys/bus/acpi/devices/${ACPI_HID}:* >/dev/null 2>&1; then
    ok "Cirrus CS35L41 amp device ($ACPI_HID) present"
  else
    warn "no $ACPI_HID (CS35L41) ACPI device found - this machine lacks the amps this fix targets."
    rc=1
  fi
  if grep -iq "${EXPECTED_SSID/:/}" /proc/asound/card*/codec#0 2>/dev/null \
     || lspci -nn 2>/dev/null | grep -iq "$EXPECTED_SSID"; then
    ok "audio subsystem id $EXPECTED_SSID detected"
  else
    warn "audio subsystem id $EXPECTED_SSID not detected (continuing)"
  fi
  return $rc
}

check_secureboot() {
  local sb="" ld="[none]"
  command -v mokutil >/dev/null 2>&1 && sb="$(mokutil --sb-state 2>/dev/null || true)"
  [ -r /sys/kernel/security/lockdown ] && ld="$(cat /sys/kernel/security/lockdown 2>/dev/null || true)"
  log "Secure Boot: ${sb:-unknown}   |   kernel lockdown: $ld"
  if printf '%s' "$sb" | grep -qi 'SecureBoot enabled' \
     || printf '%s' "$ld" | grep -qiE '\[(integrity|confidentiality)\]'; then
    warn "Secure Boot is ENABLED (kernel is locked down)."
    printf '    ACPI table overrides loaded from the initramfs are silently ignored\n'
    printf '    while Secure Boot is on, so the fix cannot take effect.\n'
    printf '    Disable Secure Boot first:\n'
    printf '      reboot -> tap F2 (or DEL) at the ASUS logo -> Security (or Boot) tab\n'
    printf '      -> Secure Boot Control -> Disabled -> save & exit -> re-run this script.\n'
    return 1
  fi
  ok "Secure Boot off / lockdown none"
  return 0
}

run_checks() {
  local rc=0
  check_os         || rc=1
  check_model      || rc=1
  check_secureboot || rc=1
  return $rc
}

# ------------------------------------------------------------------ tooling ---
ensure_tools() {
  if ! command -v iasl >/dev/null 2>&1; then
    log "installing acpica-tools (provides iasl) ..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y acpica-tools >/dev/null \
        || die "failed to install acpica-tools"
    else
      die "iasl not found and apt-get unavailable. Install the ACPICA tools (package 'acpica-tools' or 'iasl') and re-run."
    fi
  fi
  command -v cpio >/dev/null 2>&1 || die "cpio not found (install the 'cpio' package)."
  ok "build tools present (iasl, cpio)"
}

# ------------------------------------------------------------- build + apply ---
build_and_install_ssdt() {
  WORK="$(mktemp -d)"
  local dsl="$WORK/${AML_MEMBER%.aml}.dsl"
  cat > "$dsl" <<'DSL'
DefinitionBlock ("", "SSDT", 2, "CBTR", "CS35L41", 0x00000001)
{
    External (_SB_.PC00.SPI1, DeviceObj)
    External (_SB_.PC00.SPI1.SPK1, DeviceObj)

    Scope (\_SB.PC00.SPI1.SPK1)
    {
        Name (_DSD, Package ()
        {
            ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
            Package ()
            {
                Package () { "cirrus,dev-index", Package () { Zero, One } },
                Package () { "reset-gpios", Package () { ^SPK1, One, Zero, Zero, ^SPK1, One, Zero, Zero } },
                Package () { "spk-id-gpios", Package () { ^SPK1, 0x02, Zero, Zero, ^SPK1, 0x02, Zero, Zero } },
                Package () { "cirrus,speaker-position", Package () { Zero, One } },
                Package () { "cirrus,boost-type", Package () { One, One } },
                Package () { "cirrus,gpio1-func", Package () { One, One } },
                Package () { "cirrus,gpio2-func", Package () { 0x02, 0x02 } }
            }
        })
    }

    Scope (\_SB.PC00.SPI1)
    {
        Name (_DSD, Package ()
        {
            ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301"),
            Package ()
            {
                Package () { "cs-gpios", Package () { Zero, SPK1, Zero, Zero, Zero } }
            }
        })
    }
}
DSL

  log "compiling SSDT with iasl ..."
  ( cd "$WORK" && iasl -tc "$(basename "$dsl")" ) >/dev/null 2>&1 \
    || die "iasl failed to compile the SSDT"
  [ -f "$WORK/$AML_MEMBER" ] || die "iasl did not produce $AML_MEMBER"
  ok "SSDT compiled"

  log "packaging ACPI override into a cpio ..."
  mkdir -p "$WORK/cpioroot/kernel/firmware/acpi"
  cp "$WORK/$AML_MEMBER" "$WORK/cpioroot/kernel/firmware/acpi/$AML_MEMBER"
  ( cd "$WORK/cpioroot" && find kernel | cpio -H newc --create --quiet > "$WORK/$CPIO_NAME" )
  install -o root -g root -m 0644 "$WORK/$CPIO_NAME" "$BOOT_DIR/$CPIO_NAME"
  ok "installed $BOOT_DIR/$CPIO_NAME"
}

verify_installed() {
  local cfg rc=0
  cfg="$(grub_cfg_path)"
  if grep -q "$CPIO_NAME" "$cfg" 2>/dev/null; then ok "grub.cfg loads $CPIO_NAME"; else warn "grub.cfg does not reference $CPIO_NAME"; rc=1; fi
  if grep -q "$KPARAM"    "$cfg" 2>/dev/null; then ok "grub.cfg has $KPARAM";      else warn "grub.cfg missing $KPARAM";           rc=1; fi
  if [ -f "$BOOT_DIR/$CPIO_NAME" ];           then ok "cpio present in /boot";     else warn "cpio missing from /boot";           rc=1; fi
  return $rc
}

# -------------------------------------------------------------------- modes ---
do_install() {
  banner
  run_checks || die "pre-flight checks failed (see above). Nothing was changed."
  ensure_tools
  backup_grub
  build_and_install_ssdt
  add_kernel_param
  set_early_initrd
  regen_grub
  echo
  if verify_installed; then
    printf '%s%s Fix applied. %s\n' "$C_GRN" "$C_BLD" "$C_RST"
  else
    warn "applied, but verification found problems - review the output above before rebooting."
  fi
  cat <<EOF

${C_BLD}Next step: REBOOT.${C_RST}
After rebooting, test the speakers:

    speaker-test -c2 -twav -l1          # Ctrl+C to stop
    wpctl status                        # (or Settings -> Sound) should list a Speaker

Confirm the amplifiers powered on:

    sudo dmesg | grep -i cs35l41
      expect:  "Firmware Loaded - Type: spk-prot"   (not "Platform not supported")

Undo everything:   sudo ${0##*/} --uninstall
EOF
}

do_uninstall() {
  banner
  check_root || die "must run as root"
  [ -f "$GRUB_DEFAULT" ] || die "$GRUB_DEFAULT not found"
  backup_grub
  remove_kernel_param
  clear_early_initrd
  rm -f "$BOOT_DIR/$CPIO_NAME"
  rm -f "$BOOT_DIR"/acpi_ux582zw.cpio 2>/dev/null || true   # legacy ad-hoc name
  ok "removed the ACPI cpio from /boot"
  regen_grub
  cat <<EOF

${C_BLD}Uninstalled.${C_RST} Reboot to return to the stock audio driver.
Note: this does not re-enable Secure Boot - do that in your UEFI/BIOS if you want it back.
EOF
}

do_check() {
  banner
  if run_checks; then
    ok "all checks passed - this machine is ready for the fix"
  else
    warn "one or more checks failed (see above)"
  fi
  echo
  log "current install state:"
  [ -f "$BOOT_DIR/$CPIO_NAME" ]              && ok "cpio installed: $BOOT_DIR/$CPIO_NAME" || warn "cpio not installed"
  grep -q "$KPARAM" "$GRUB_DEFAULT" 2>/dev/null && ok "$KPARAM present in $GRUB_DEFAULT"   || warn "$KPARAM not set in $GRUB_DEFAULT"
  echo
  log "no changes were made (--check)."
}

# --------------------------------------------------------------------- main ---
for a in "${@:-}"; do
  case "$a" in
    --uninstall) MODE="uninstall" ;;
    --check)     MODE="check" ;;
    --force)     FORCE=1 ;;
    -h|--help)   usage ;;
    "")          ;;
    *)           die "unknown argument: $a  (try --help)" ;;
  esac
done

# Re-exec with sudo for install/uninstall when possible.
if [ "$MODE" != "check" ] && [ "$(id -u)" -ne 0 ]; then
  if [ -f "${BASH_SOURCE[0]:-}" ]; then
    exec sudo -- "$0" "$@"
  fi
  die "please run as root:  sudo $0 $*    (or pipe the one-liner through 'sudo bash')"
fi

case "$MODE" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check ;;
esac
