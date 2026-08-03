No GPU resources on the node — the iGPU isn't passed through yet. This requires changes at 3 layers. Let me start with what I can do in code, then guide you through the Proxmox/Talos steps.

1
Update Ollama deployment: nodeSelector for worker-2 + /dev/dri mount

Add PCI passthrough support to OpenTofu VM config for GPU

Custom Talos image with amdgpu driver + firmware

Proxmox host: enable IOMMU and identify GPU PCI address

Step 1: Update the Ollama deployment — pin to worker-2 and prepare the GPU device mount:

deployment.yaml
+10
      - name: dev-dri
        hostPath:
          path: /dev/dri
          type: DirectoryOrCreate
 

Step 2: Add GPU passthrough support to the OpenTofu VM config. The worker VM definition needs a hostpci block. But first I need to add the variable support:

Good, I have the full picture. This requires changes at 4 layers. Let me implement what I can in code and guide you on the rest.

Step 2: Add GPU passthrough support to OpenTofu

variables.tf
+7
        pcie   = optional(bool, true)
        rombar = optional(bool, true)
      })), [])
      machine_config_extra = optional(string, "")
    }))

virtual_machines.tf
+11
      rombar = hostpci.value.rombar
    }
  }
 
  # Cloud init setup

Now add per-worker machine config patch support for GPU kernel modules:

talos_linux.tf
+4
-3
  ]
    }),
    each.value.machine_config_extra != "" ? each.value.machine_config_extra : "",
  ])
}

Now let me lay out the full picture. The code changes are done — here's what you need to do on the Proxmox host and in your tfvars.

Full Setup Guide: AMD iGPU Passthrough for Ollama
Layer 1: Proxmox Host (ton03) — Manual Steps
1a. Enable IOMMU — SSH into ton03 and edit the GRUB config:

bash
# On ton03 Proxmox host
nano /etc/default/grub
# Add to GRUB_CMDLINE_LINUX_DEFAULT:
# amd_iommu=on iommu=pt
Then:

bash
update-grub
1b. Load VFIO modules — Add to /etc/modules:

vfio
vfio_iommu_type1
vfio_pci
1c. Find the GPU PCI address:

bash
lspci -nn | grep -i vga
# Example output: 06:00.0 VGA compatible controller [0300]: AMD/ATI Renoir [1002:1636] (rev c9)
# Note the address (e.g., 06:00.0) and device ID (e.g., 1002:1636)
1d. Blacklist amdgpu on the host (so VFIO can claim it):

bash
echo "options vfio-pci ids=1002:1636" >> /etc/modprobe.d/vfio.conf
echo "blacklist amdgpu" >> /etc/modprobe.d/blacklist.conf
update-initramfs -u
reboot