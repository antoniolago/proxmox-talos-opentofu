#!/bin/bash
# Proxmox hook script: auto-restart VMs when they stop unexpectedly
# Hook phases:
#   pre-start  - before VM starts
#   post-start - after VM starts
#   pre-stop   - before VM stops
#   post-stop  - after VM stops
#
# This script restarts the VM on post-stop to ensure
# Kubernetes worker/control-plane VMs are never left stopped.
# Uses a marker file to allow intentional stops (tofu destroy).

MARKER="/var/run/vm-${1}-allow-stop"

case "${2}" in
  post-stop)
    # Don't restart if marker exists (intentional stop)
    if [ -f "${MARKER}" ]; then
      rm -f "${MARKER}"
      exit 0
    fi
    # Restart the VM
    /usr/sbin/qm start "${1}" || true
    ;;
  pre-stop)
    # Do nothing - we handle restart on post-stop
    ;;
esac
