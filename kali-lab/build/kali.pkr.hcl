packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1.0"
    }
  }
}

########## Variables ##########
variable "iso_url" {
  type        = string
  description = "Kali installer ISO — get the current URL from https://www.kali.org/get-kali/. Kali puts the version in the filename, so bump this each release."
  default     = "https://cdimage.kali.org/current/kali-linux-2026.2-installer-amd64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum (pinned to the 2026.2 installer-amd64 ISO). Bump alongside iso_url each release — the value is on https://cdimage.kali.org/current/SHA256SUMS. Alternatively set 'file:https://cdimage.kali.org/current/SHA256SUMS' to auto-resolve by filename (works only while iso_url's basename is listed there)."
  default     = "sha256:6dbefacc95e3b556c19c48e8bae39b8b505e2d3a1aba0bfb7ab62b036c3d2ba3"
}

variable "metapackage" {
  type        = string
  description = "Kali metapackage to install. Lean, SSH-only lab: kali-linux-headless. Alt: kali-linux-core / kali-linux-default"
  default     = "kali-linux-headless"
}

# Build-time GUI toggle: when true, the playbook also installs the VNC session
# stack (x11vnc, xvfb, fluxbox) so the golden image is ready for VNC/noVNC.
# X11 forwarding is always enabled regardless of this flag.
variable "enable_gui_vnc" {
  type        = bool
  description = "Bake the optional VNC session stack into the image"
  default     = false
}

# When true, bake a full XFCE desktop + lightdm (shown by SPICE/virt-viewer),
# in addition to the tool metapackage. Heavier and slower than the headless build.
variable "enable_desktop" {
  type        = bool
  description = "Bake a full XFCE desktop into the image"
  default     = false
}

# When true, run Ansible with -vvvv (task/module detail). NB: this does NOT
# stream apt's own download progress — the apt module buffers until it returns.
# To watch apt live, SSH/VNC into the guest and `tail -f /var/log/dpkg.log`.
variable "ansible_verbose" {
  type        = bool
  description = "Run the Ansible provisioner with -vvvv"
  default     = false
}

variable "disk_size" {
  type    = string
  default = "20480" # MiB
}

variable "memory" {
  type    = number
  default = 4096
}

variable "cpus" {
  type    = number
  default = 2
}

########## Source ##########
source "qemu" "kali" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  output_directory = "output-kali"
  vm_name          = "kali-golden.qcow2"
  format           = "qcow2"
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"

  accelerator = "kvm"
  cpus        = var.cpus
  memory      = var.memory

  # Serve the preseed dir over HTTP to the installer
  http_directory = "http"

  # SSH login Packer uses AFTER the install completes (see preseed accounts)
  ssh_username = "kali"
  ssh_password = "kali"
  ssh_timeout  = "60m" # the install itself is long

  shutdown_command = "sudo systemctl poweroff"

  # Set to false to watch the installer live in a QEMU window while debugging.
  headless = true

  # NOTE: the boot_command is the single most ISO-specific, fragile part.
  # This targets the BIOS/isolinux Kali installer: <esc> drops to the isolinux
  # 'boot:' prompt, then we type 'install <kernel params>'.
  #
  # Two robustness measures vs a stall on the language screen:
  #   * boot_wait 15s + a <wait> after <esc> so the menu is actually ready
  #     before keystrokes are sent (otherwise they are swallowed and the
  #     default menu entry boots WITHOUT the preseed);
  #   * locale + keymap passed as KERNEL PARAMS, because those questions are
  #     asked before the preseed file is fetched, so priority=critical alone
  #     is not enough to skip them.
  boot_wait = "15s"
  boot_command = [
    "<esc><wait>",
    "install ",
    "auto=true ",
    "priority=critical ",
    "preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg ",
    "debian-installer/locale=en_US.UTF-8 ",
    "keyboard-configuration/xkb-keymap=us ",
    "console-setup/ask_detect=false ",
    "netcfg/get_hostname=kali ",
    "netcfg/get_domain=lab.local ",
    "<enter>"
  ]
}

########## Build ##########
build {
  sources = ["source.qemu.kali"]

  provisioner "ansible" {
    playbook_file = "ansible/playbook.yml"
    user          = "kali"
    # profile_tasks prints per-task timing at the end — handy to see which step
    # was the long one (usually the metapackage install).
    ansible_env_vars = ["ANSIBLE_CALLBACKS_ENABLED=profile_tasks"]
    extra_arguments = concat(
      ["--extra-vars", "kali_metapackage=${var.metapackage} enable_gui_vnc=${var.enable_gui_vnc} enable_desktop=${var.enable_desktop}"],
      var.ansible_verbose ? ["-vvvv"] : []
    )
  }

  post-processor "manifest" {
    output = "manifest.json"
  }
}
