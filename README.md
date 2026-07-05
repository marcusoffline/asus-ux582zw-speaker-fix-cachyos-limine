# ASUS Zenbook Pro Duo 15 OLED (UX582ZW) — CachyOS + Limine Internal Speakers Fix

This is a fork of [CodingButter's fix](https://github.com/CodingButter/asus-ux582zw-speaker-fix), but for my device running CachyOS Handheld Edition with Limine bootloader.

Makes the **internal speakers work on Linux** on the ASUS Zenbook Pro Duo 15 OLED
**UX582ZW**. Out of the box the internal speakers are silent — only Bluetooth,
HDMI, and the 3.5 mm headphone jack produce sound.

This repo gives a script to fix it.

Feel free to feed this to an AI model to adapt for your setup, as it was originally designed for CachyOS Handheld Edition running on Limine bootloader.

1. **Disable Secure Boot** in your UEFI/BIOS.
2. Place install-limine.sh in your Downloads folder.
3. Run the following command in Terminal/Konsole.
   
cd ~/Downloads

sudo bash install-limine.sh

4. **Reboot.** Speakers work.
   

Huge thanks to CodingButter again, for the original fix!
