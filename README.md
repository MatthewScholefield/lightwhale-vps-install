# Lightwhale VPS Installer

Install [Lightwhale](https://lightwhale.asklandd.dk/) on a VPS with an interactive Bash script. It sets up BIOS GRUB, downloads the OS ISO, and prepares persistent storage on the same disk.

**The selected disk will be completely erased. Back up anything important first.**

## Requirements

- An **x86-64 VPS with legacy BIOS boot** (not UEFI-only).
- A provider-supplied live/rescue environment and console access. Debian/Ubuntu recommended.
- A disk named `/dev/sdX`, `/dev/nvme…`, or `/dev/mmcblk…`. For `/dev/vda`, switch to a SATA/SCSI controller if your provider supports it.

## 1. Boot into rescue mode

Boot a **live image or emergency recovery OS** from your VPS control panel. An Ubuntu installer image works—open its live shell. **Do not install Ubuntu onto the disk.**

Open a root shell (`sudo -i` if needed). On Debian/Ubuntu, install the required tools in this temporary environment:

```bash
apt-get update && apt-get install -y \
  bash coreutils mawk curl ca-certificates util-linux mount \
  parted e2fsprogs udev grub-pc-bin grub2-common
```

## 2. Run the installer

```bash
curl -fL --proto '=https' --proto-redir '=https' \
  -o install-bios.sh \
  https://raw.githubusercontent.com/MatthewScholefield/lightwhale-vps-install/main/install-bios.sh &&
  bash install-bios.sh
```

Choose the target disk, press Enter for the latest Lightwhale ISO, and confirm the erase prompt. The script refuses disks with mounted filesystems or active swap; release those in the rescue environment if needed.

When it finishes, **disable rescue mode / detach the live ISO and reboot from the VPS disk in BIOS mode**. Lightwhale automatically sets up its data partition on first boot and reuses it afterward. Disconnect unrelated data disks during setup.

Log in through the provider console with **`op` / `opsecret`**, change the password with `passwd op`, and configure networking if your provider requires it. Restrict public access until setup is complete.

> Unofficial, experimental installer. Partitioning and GRUB configuration checks pass; a full VPS install/reboot has not yet been verified. Rerunning the installer erases data—it is not an upgrade tool.
