output "kali_ip" {
  description = "First leased IPv4 of the VM"
  value = try(
    libvirt_domain.kali.network_interface[0].addresses[0],
    "pending — run: virsh net-dhcp-leases default"
  )
}
