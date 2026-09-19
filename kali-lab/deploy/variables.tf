variable "golden_volume" {
  type        = string
  description = "Name of the golden volume in the libvirt pool (put there by `make install`)"
  default     = "kali-golden.qcow2"
}

variable "vm_name" {
  type        = string
  description = "Name of the VM / libvirt domain"
  default     = "kali-lab-01"
}

variable "pool" {
  type        = string
  description = "libvirt storage pool"
  default     = "default"
}

variable "network" {
  type        = string
  description = "libvirt network to attach the VM to"
  default     = "default"
}

variable "memory_mb" {
  type        = number
  description = "RAM in MiB"
  default     = 4096
}

variable "vcpu" {
  type        = number
  description = "Number of virtual CPUs"
  default     = 2
}

variable "disk_gb" {
  type        = number
  description = "Disk size in GiB (grown from the golden image)"
  default     = 30
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key injected via cloud-init"
  default     = "~/.ssh/id_ed25519.pub"
}

variable "data_disk_path" {
  type        = string
  description = "Absolute path to a pre-existing raw data image to attach as /data (empty = none). Managed outside Terraform by `make data-create` so it survives destroy/redeploy."
  default     = ""
}

variable "enable_spice_agent" {
  type        = bool
  description = "Apply the SPICE/virtio XSLT to the domain XML. Needs `xsltproc` on the host (dmacvicar shells out to it). Set false for headless/CLI-only VMs to drop that dependency; desktop VMs need it for the virtio-gpu video, clipboard + dynamic resize, and the virtiofs plumbing."
  default     = true
}

variable "share_path" {
  type        = string
  description = "Absolute host directory shared into the guest over virtiofs at /mnt/host (empty = no share). Requires enable_spice_agent (the XSLT adds the shared-memory backing + virtiofs driver)."
  default     = ""
}

variable "share_tag" {
  type        = string
  description = "virtiofs mount tag the guest uses to mount the shared folder"
  default     = "hostshare"
}

variable "swap_size" {
  type        = string
  description = "cloud-init swap file size on first boot (e.g. 2G); empty = no swap. There is no swap partition (single-partition golden), so this provides swap."
  default     = ""
}
