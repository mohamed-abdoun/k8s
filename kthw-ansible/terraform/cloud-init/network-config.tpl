version: 2
ethernets:
  # Match by virtio_net driver — works on both x86 and ARM KVM VMs regardless
  # of the interface name (enp1s0, ens3, eth0, etc.)
  primary:
    match:
      driver: virtio_net
    dhcp4: false
    addresses:
      - ${ip}/24
    routes:
      - to: default
        via: ${gateway}
    nameservers:
      addresses:
        - 8.8.8.8
        - 1.1.1.1
