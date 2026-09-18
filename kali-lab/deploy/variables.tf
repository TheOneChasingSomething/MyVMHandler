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
