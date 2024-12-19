#!/bin/bash
# Prerequisites: apt install libguestfs-tools
# Usage: ./create_ubuntu_lts_template.sh [ubuntu codename] [lvm_pool] [img_id] [bridge]
set -e

codename=${1:-noble}
lvm_pool=${2:-local-lvm}
img_id=${3:-9000}
bridge=${4:-vmbr0}

echo "Creating Ubuntu template for $codename"

echo "Clearing up old img for ${codename}"
image_file=${codename}-server-cloudimg-amd64.img
echo "Image file: $image_file"

[[ -e $image_file ]] && rm -f $image_file

echo "Clearing up old template ${img_id}"
qm status ${img_id} && qm destroy ${img_id} --purge

echo "Downloading image file"
wget https://cloud-images.ubuntu.com/${codename}/current/$image_file
virt-customize -a $image_file --install qemu-guest-agent
qm create ${img_id} --name "ubuntu-${codename}-cloudinit-template" --memory 2048 --cores 2 --net0 virtio,bridge=${bridge}
qm importdisk ${img_id} $image_file ${lvm_pool}
qm set ${img_id} --scsihw virtio-scsi-pci --scsi0 ${lvm_pool}:vm-${img_id}-disk-0
qm set ${img_id} --boot c --bootdisk scsi0
qm set ${img_id} --ide2 ${lvm_pool}:cloudinit
qm set ${img_id} --serial0 socket --vga serial0
qm set ${img_id} --agent enabled=1
qm template ${img_id}
