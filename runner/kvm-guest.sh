#!/usr/bin/env bash
# Fixed systemd guest entrypoint. Its separate DynamicUser receives no runner
# administrator credential, host mounts or candidate-controlled command line.
set -euo pipefail

state=/var/lib/hesperus-kvm-guest
input=/etc/hesperus-kvm
test -r "$input/base.qcow2"
test -r "$input/seed.iso"
test ! -L "$state/guest.qcow2"
# systemd starts this only after the prior instance has terminated. A guest is
# never reused across candidates, including daemon crashes and canceled jobs.
if [ -e "$state/guest.qcow2" ]; then rm -- "$state/guest.qcow2"; fi
qemu-img create -q -f qcow2 -F qcow2 -b "$input/base.qcow2" "$state/guest.qcow2" 64G
exec qemu-system-x86_64 -no-user-config -nodefaults -enable-kvm \
  -machine q35,accel=kvm -cpu host -smp 2 -m 4096 \
  -name hesperus-kvm-routine -nographic -monitor none \
  -serial "file:$state/console.log" -no-reboot \
  -drive "file=$state/guest.qcow2,if=virtio,format=qcow2,cache=none" \
  -drive "file=$input/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev user,id=e0,ipv6=off -device virtio-net-pci,netdev=e0 \
  -device vhost-vsock-pci,guest-cid=14695 \
  -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
