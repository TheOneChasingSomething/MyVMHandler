terraform {
  required_version = ">= 1.5.0"
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # Pin to the 0.8 series: v0.9.0 changed the resource schema (libvirt_volume
      # source/format/size, libvirt_domain blocks, cloudinit_disk) and would break
      # this config. "~> 0.8.0" means >= 0.8.0, < 0.9.0.
      version = "~> 0.8.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Per-VM copy-on-write disk backed DIRECTLY by the golden volume already in the
# pool (put there by `make install`, world-readable 0644). This avoids a full
# ~15 GB copy of the golden per VM AND the root:600 backing-file permission issue
# (libvirt relabels the top disk but not a copied backing file — dmacvicar #546).
resource "libvirt_volume" "kali_disk" {
  name             = "${var.vm_name}.qcow2"
  pool             = var.pool
  base_volume_name = var.golden_volume
  base_volume_pool = var.pool
  format           = "qcow2"
  size             = var.disk_gb * 1024 * 1024 * 1024
}

# NoCloud seed disk: hostname + SSH key + DHCP network config for this VM.
# network_config makes cloud-init bring eth0 up via DHCP at first boot,
# regardless of what interface name the baked image configured at install time.
resource "libvirt_cloudinit_disk" "kali_init" {
  name = "${var.vm_name}-cloudinit.iso"
  pool = var.pool
  user_data = templatefile("${path.module}/cloud_init.yaml.tftpl", {
    hostname   = var.vm_name
    ssh_pubkey = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
  network_config = <<-EOT
    version: 2
    ethernets:
      eth0:
        dhcp4: true
  EOT
}

resource "libvirt_domain" "kali" {
  name       = var.vm_name
  memory     = var.memory_mb
  vcpu       = var.vcpu
  cloudinit  = libvirt_cloudinit_disk.kali_init.id
  qemu_agent = true

  cpu {
    mode = "host-passthrough"
  }

  network_interface {
    network_name   = var.network
    wait_for_lease = true
  }

  disk {
    volume_id = libvirt_volume.kali_disk.id
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}
