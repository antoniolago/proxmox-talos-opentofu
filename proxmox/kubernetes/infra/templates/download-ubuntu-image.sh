#!/usr/bin/env bash
set -e
NODE="192.168.88.242"
IMG="/var/lib/vz/template/iso/ubuntu-24.10-server-cloudimg-amd64.img"

if ! ssh root@$NODE "[ -f $IMG ]" 2>/dev/null; then
  echo "=== Downloading Ubuntu cloud image on ton03 ==="
  ssh root@$NODE "wget -q --show-progress -O $IMG 'https://cloud-images.ubuntu.com/releases/24.10/release/ubuntu-24.10-server-cloudimg-amd64.img'"
fi
echo "Image: $(ssh root@$NODE "ls -lh $IMG | awk '{print \$5}'")"
