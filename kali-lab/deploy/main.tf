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

# Provenance: read the host-side build manifest that `make install` placed next
# to the golden (build/manifests/<golden>.json) and fold a compact summary into
# the libvirt domain <description>, so `virsh desc <vm>` / `make info` can trace
# a running VM back to its golden without booting it. try() keeps deploy working
# when no manifest is present (e.g. a golden installed before this feature).
locals {
  golden_stem   = replace(var.golden_volume, ".qcow2", "")
  manifest_path = "${path.module}/../build/manifests/${local.golden_stem}.json"
  manifest      = try(jsondecode(file(local.manifest_path)), {})

  domain_description = try(
    format(
      "golden=%s | os=%s %s | kernel=%s | upgradable@bake=%s | built=%s | commit=%s",
      local.golden_stem,
      try(local.manifest.os.distribution, "?"),
      try(local.manifest.os.version, "?"),
      try(local.manifest.os.kernel, "?"),
      try(local.manifest.update_level.upgradable_packages, "?"),
      try(local.manifest.build_date, "?"),
      try(local.manifest.pipeline_commit, "?")
    ),
    "golden=${local.golden_stem}"
  )
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
    data_disk  = var.data_disk_path != ""
    share      = var.share_path != ""
    share_tag  = var.share_tag
    swap_size  = var.swap_size
  })
  network_config = <<-EOT
    version: 2
    ethernets:
      eth0:
        dhcp4: true
  EOT
}

resource "libvirt_domain" "kali" {
  name        = var.vm_name
  description = local.domain_description
  memory      = var.memory_mb
  vcpu        = var.vcpu
  cloudinit   = libvirt_cloudinit_disk.kali_init.id
  qemu_agent  = true

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

  # Optional host<->guest shared folder over virtiofs. The XSLT (spice.xsl)
  # turns this into a virtiofs mount and adds the shared-memory backing the
  # guest needs; cloud-init mounts it on /mnt/host. Empty share_path => none.
  dynamic "filesystem" {
    for_each = var.share_path == "" ? [] : [var.share_path]
    content {
      source     = filesystem.value
      target     = var.share_tag
      accessmode = "passthrough"
      readonly   = false
    }
  }

  # Optional persistent data disk. Attached by PATH to a pre-existing raw image
  # that Terraform does NOT own (created out-of-band by `make data-create`), so
  # `terraform destroy` removes only the domain + root overlay and the data image
  # survives — letting you destroy and redeploy onto a newer golden while /data
  # is preserved. Empty var.data_disk_path (the default) => no second disk.
  dynamic "disk" {
    for_each = var.data_disk_path == "" ? [] : [var.data_disk_path]
    content {
      file = disk.value
    }
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

  # Patch the generated domain XML: QXL video + SPICE vdagent channel, so
  # virt-viewer gets shared clipboard and dynamic resolution (with the guest's
  # spice-vdagent, installed by the DESKTOP bake). dmacvicar applies this by
  # shelling out to `xsltproc`, so the block is gated on enable_spice_agent
  # (SPICE=): drop it (SPICE=false) for headless VMs that don't need it and to
  # avoid requiring xsltproc on the host.
  dynamic "xml" {
    for_each = var.enable_spice_agent ? [1] : []
    content {
      xslt = file("${path.module}/spice.xsl")
    }
  }
}
