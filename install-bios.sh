#!/usr/bin/env bash
# Provision a dedicated disk for legacy BIOS Lightwhale boot and persistence.
set -Eeuo pipefail
export LC_ALL=C

usage() {
    printf '%s\n' \
        'Usage: sudo bash install-bios.sh' \
        '' \
        'Interactive, destructive installer for a dedicated disk (legacy BIOS only).' \
        'Creates BIOS GRUB + an ext2 ISO partition + a Lightwhale data partition.' \
        'Run from your VPS provider live/rescue OS, not the target disk or stock Lightwhale.' \
        'Requires Bash 4+, curl, util-linux, parted, e2fsprogs, and GRUB i386-pc modules.' \
        'The target disk is erased only after an explicit confirmation.'
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
if (( $# )); then usage >&2; exit 2; fi

bold='' dim='' reset=''
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    bold=$'\e[1m'; dim=$'\e[2m'; reset=$'\e[0m'
fi
say() { printf '\n%s%s%s\n' "$bold" "$*" "$reset"; }
die() { printf '\nError: %s\n' "$*" >&2; exit 1; }
step() { say "$1 / 4  $2"; }
work=''
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $work ]]; then
        local failed=0 path
        for path in "$work/boot" "$work/iso"; do
            if mountpoint -q "$path"; then
                umount "$path" || failed=1
            fi
        done
        if (( failed )); then
            printf 'Could not unmount temporary filesystems; leaving %s intact.\n' "$work" >&2
            status=1
        else
            rm -rf -- "$work"
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "\nInstallation failed at line %s. Do not boot the target until installation succeeds.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

(( EUID == 0 )) || die 'Run with sudo bash install-bios.sh.'
[[ -t 0 && -t 1 ]] || die 'An interactive terminal is required.'
for cmd in curl lsblk blkid blockdev parted partprobe udevadm mkfs.ext2 wipefs mount umount mountpoint findmnt readlink awk stat mktemp sync rm mkdir sleep cp cat; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
if command -v grub-install >/dev/null; then
    grub_install=$(command -v grub-install)
elif command -v grub2-install >/dev/null; then
    grub_install=$(command -v grub2-install)
else
    die 'Install GRUB tools and the i386-pc (BIOS) modules first.'
fi
bios_modules=''
for dir in /usr/lib/grub/i386-pc /usr/lib/grub2/i386-pc /usr/share/grub/i386-pc /usr/share/grub2/i386-pc; do
    if [[ -f $dir/modinfo.sh ]]; then bios_modules=$dir; break; fi
done
[[ -n $bios_modules ]] || die 'GRUB BIOS modules missing (Debian: grub-pc-bin; Fedora: grub2-pc-modules).'

say 'Lightwhale · BIOS disk setup'
printf '%s\n' \
    'This erases the ENTIRE selected disk, including every existing partition.' \
    'Boot the result in legacy BIOS / CSM mode, not UEFI-only mode.' \
    'On first boot Lightwhale will format its data partition automatically.'
printf '\n'
lsblk -dp -o NAME,SIZE,MODEL,TRAN,TYPE
printf '\nTarget whole disk (for example /dev/sdb; blank cancels): '
IFS= read -r device
[[ -n $device ]] || exit 0
device=$(readlink -f -- "$device")
[[ -b $device ]] || die 'The target is not a block device.'
[[ $(lsblk -dnro TYPE "$device") == disk ]] || die 'Select a whole disk, not a partition, loop device, or mapped device.'
# Current Lightwhale's partition-renaming code supports only these device names.
[[ $device =~ ^/dev/(sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)$ ]] \
    || die 'Lightwhale provisioning requires an sd*, mmcblk*, or nvme*n* disk (use SATA/SCSI rather than virtio-blk in a VM).'

check_idle() {
    local node name mounts holder
    [[ $(blockdev --getro "$device") == 0 ]] || die 'The disk is read-only.'
    mounts=$(lsblk -nr -o MOUNTPOINTS "$device")
    [[ -z ${mounts//[[:space:]]/} ]] || die 'Target has mounted filesystems or active swap. Unmount/disable them first.'
    while IFS= read -r node; do
        name=${node##*/}
        for holder in /sys/class/block/"$name"/holders/*; do
            [[ ! -e $holder ]] || die "Target is in use by ${holder##*/} (RAID/LVM/device mapper)."
        done
        if findmnt -rn -S "$node" >/dev/null; then die "Target is mounted: $node"; fi
    done < <(lsblk -nrpo NAME "$device")
}
check_idle
initial_identity=$(lsblk -dnbo MAJ:MIN,SIZE "$device")

printf '\nISO HTTPS URL [https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso]: '
IFS= read -r url
url=${url:-https://lightwhale.asklandd.dk/download/lightwhale-latest-x86.iso}
[[ $url == https://* ]] || die 'Use an HTTPS download URL.'
work=$(mktemp -d /var/tmp/lightwhale-install.XXXXXXXX)
mkdir "$work/iso" "$work/boot"
say 'Downloading and inspecting ISO before touching the disk'
printf '%sTemporary download: %s%s\n' "$dim" "$work/lightwhale.iso" "$reset"
curl --fail --location --proto '=https' --proto-redir '=https' \
    --retry 3 --connect-timeout 30 --progress-bar --output "$work/lightwhale.iso" "$url"
mount -t iso9660 -o loop,ro,nosuid,nodev,noexec "$work/lightwhale.iso" "$work/iso"
for file in boot/lightwhale-kernel boot/lightwhale-rootfs boot/grub/grub.cfg; do
    [[ -s $work/iso/$file ]] || die "Not a supported Lightwhale ISO: missing $file"
done
# Use the actual image's generated value rather than guessing RAM disk size.
ramdisk_kb=$(awk '{ for (i=1; i<=NF; i++) if ($i ~ /^ramdisk_size=[0-9]+$/) { sub(/^ramdisk_size=/,"",$i); print $i; exit } }' "$work/iso/boot/grub/grub.cfg")
[[ $ramdisk_kb =~ ^[0-9]+$ ]] || die 'ISO has no numeric ramdisk_size in its GRUB configuration.'
rootfs_bytes=$(stat -c %s "$work/iso/boot/lightwhale-rootfs")
(( ramdisk_kb >= (rootfs_bytes + 1023) / 1024 )) || die 'ISO ramdisk_size is smaller than its root filesystem.'
umount "$work/iso"
iso_bytes=$(stat -c %s "$work/lightwhale.iso")
boot_mib=$(( (iso_bytes + 1048575) / 1048576 + 512 ))
(( boot_mib >= 2048 )) || boot_mib=2048
boot_end=$((3 + boot_mib))
disk_bytes=$(blockdev --getsize64 "$device")
(( disk_bytes / 1048576 > boot_end + 1025 )) || die 'Disk too small: need room for the ISO boot partition plus at least 1 GiB of data.'

say "Proposed layout: $device"
printf '  Partition 1   2 MiB       BIOS GRUB embedding area\n'
printf '  Partition 2   %s MiB    ext2; /iso/lightwhale.iso and GRUB\n' "$boot_mib"
printf '  Partition 3   remainder   Linux data; name lightwhale-please-format-me\n'
printf '\nALL DATA ON %s WILL BE LOST.\n' "$device"
printf 'Type exactly "ERASE %s" to continue: ' "$device"
IFS= read -r confirmation
[[ $confirmation == "ERASE $device" ]] || { say 'Cancelled. Target disk unchanged.'; exit 0; }
[[ $(lsblk -dnbo MAJ:MIN,SIZE "$device") == "$initial_identity" ]] || die 'Target device identity changed; restart the installer.'
check_idle

step 1 'Creating GPT and BIOS boot partitions'
parted -s -a optimal "$device" -- \
    mklabel gpt \
    mkpart BIOS-GRUB 1MiB 3MiB \
    set 1 bios_grub on \
    mkpart LIGHTWHALE-BOOT ext2 3MiB "${boot_end}MiB" \
    mkpart lightwhale-please-format-me ext4 "${boot_end}MiB" 100%
partprobe "$device"
udevadm settle
# Ask the kernel for partition names rather than concatenating device suffixes.
boot_part=''; data_part=''
for attempt in {1..10}; do
    boot_part=$(lsblk -nrpo NAME,PARTLABEL "$device" | awk '$2 == "LIGHTWHALE-BOOT" { print $1 }')
    data_part=$(lsblk -nrpo NAME,PARTLABEL "$device" | awk '$2 == "lightwhale-please-format-me" { print $1 }')
    if [[ -b $boot_part && -b $data_part ]]; then break; fi
    sleep 1
done
[[ -b $boot_part && -b $data_part ]] || die 'New partition devices did not appear.'
# Remove stale filesystem signatures that could bypass first-boot provisioning.
wipefs --all "$data_part"
mkfs.ext2 -F -L LWBOOT "$boot_part"
mount -o nosuid,nodev "$boot_part" "$work/boot"
mkdir -p "$work/boot/iso" "$work/boot/boot/grub"

step 2 'Writing ISO and installing BIOS GRUB'
# Keep the ISO as a file; never dd it over the shared disk or its partition table.
cp -- "$work/lightwhale.iso" "$work/boot/iso/lightwhale.iso"
boot_uuid=$(blkid -s UUID -o value "$boot_part")
[[ $boot_uuid =~ ^[0-9a-fA-F-]+$ ]] || die 'Could not determine boot filesystem UUID.'
cat > "$work/boot/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry 'Lightwhale' {
    insmod part_gpt
    insmod ext2
    insmod loopback
    insmod iso9660
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root $boot_uuid
    loopback loop /iso/lightwhale.iso
    linux (loop)/boot/lightwhale-kernel root=/dev/ram0 ramdisk_size=$ramdisk_kb console=tty0 consoleblank=300
    initrd (loop)/boot/lightwhale-rootfs
}
EOF
"$grub_install" --target=i386-pc --directory="$bios_modules" \
    --boot-directory="$work/boot/boot" --modules='part_gpt ext2 loopback iso9660 search_fs_uuid linux' \
    --recheck "$device"

step 3 'Checking the data partition opt-in'
[[ $(lsblk -dnro PARTLABEL "$data_part") == lightwhale-please-format-me ]] || die 'Wrong data partition name.'
[[ $(lsblk -dnro PARTTYPE "$data_part") == 0fc63daf-8483-4772-8e79-3d69d8477de4 ]] || die 'Wrong data partition type.'
printf 'Ready: %s (Lightwhale will format it; no raw magic header is needed).\n' "$data_part"
sync
umount "$work/boot"

step 4 'Installation complete'
printf '\n%s\n' \
    "Restart and select $device in the firmware's legacy BIOS / CSM boot menu." \
    'Disable VPS rescue mode and detach the live ISO. UEFI-only boot is not supported.' \
    'First boot: Lightwhale formats the data partition and enables persistence.' \
    'Later boots: Lightwhale mounts the existing lightwhale-data filesystem.' \
    'An existing lightwhale-data filesystem on another disk takes precedence;' \
    'other magic-named partitions may also be formatted. Disconnect unrelated data disks.' \
    'Default login: op / opsecret. Change the password before exposing the machine.' \
    'Future upgrades: replace /iso/lightwhale.iso and update ramdisk_size in grub.cfg;' \
    'never write an ISO over this whole disk.'
