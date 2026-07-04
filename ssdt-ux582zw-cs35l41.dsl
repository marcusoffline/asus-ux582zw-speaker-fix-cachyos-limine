/*
 * ssdt-ux582zw-cs35l41.dsl
 *
 * ACPI SSDT override that supplies the missing _DSD for the two Cirrus
 * Logic CS35L41 speaker amplifiers on an ASUS Zenbook Pro Duo 15 OLED
 * (UX582ZW).
 *
 * The stock firmware describes the amp device (\_SB.PC00.SPI1.SPK1,
 * _HID "CSC3551", _SUB "10431A8F") with a correct _CRS but *no* _DSD, and
 * this model is not in the kernel's cs35l41 quirk tables. As a result the
 * cs35l41-hda driver aborts with:
 *
 *     cs35l41-hda ...: Failed property cirrus,dev-index: -22
 *     cs35l41-hda ...: error -EINVAL: Platform not supported
 *
 * so the amps never power on and the internal speakers stay silent, even
 * though the Realtek ALC294 codec is happily driving the (unamplified)
 * speaker pin. This SSDT injects the _DSD the driver needs.
 *
 * The GPIO resource indices and property values are taken from the
 * validated SSDT for the structurally identical ASUS Zenbook UX3405MA
 * (_SUB 10431A63): both machines expose the same _CRS resource ordering
 * (2x SPI chip-select, 2x output GPIO, 1x input GPIO, 1x shared input +
 * GpioInt). No boost current/inductor parameters are supplied, which
 * selects EXTERNAL boost -- the safe configuration for this hardware.
 * (The "you could damage the speakers" warning that circulates for
 * CS35L41 SSDT patches applies to INTERNAL-boost misconfiguration.)
 *
 * Requires Secure Boot DISABLED: with Secure Boot on, the kernel runs in
 * lockdown "integrity" mode, which silently ignores ACPI table overrides
 * loaded from the initramfs.
 */
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
