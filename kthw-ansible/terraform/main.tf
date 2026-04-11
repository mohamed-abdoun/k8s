terraform {
  required_version = ">= 1.5"
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# ── Locals ────────────────────────────────────────────────────────────────────
locals {
  lb_ip = "${var.subnet}.${var.lb_last_octet}"

  # aarch64 uses the "virt" machine type; x86_64 uses "pc"
  machine_type = (var.arch == "arm64" || var.arch == "aarch64") ? "virt" : "pc"

  # cloud-init is always attached as an IDE CD-ROM by the provider, but neither
  # "virt" (aarch64) nor modern "pc" guarantees an IDE controller. Patch the
  # domain XML to switch the CD-ROM bus to scsi and drop the IDE-specific
  # address element so libvirt can place it on the virtio-scsi controller.
  cloudinit_scsi_xslt = <<-XSLT
    <?xml version="1.0" ?>
    <xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
      <xsl:output omit-xml-declaration="yes" indent="yes"/>
      <xsl:template match="node()|@*">
        <xsl:copy><xsl:apply-templates select="node()|@*"/></xsl:copy>
      </xsl:template>
      <xsl:template match="/domain/devices/disk[@device='cdrom']/target/@bus">
        <xsl:attribute name="bus">scsi</xsl:attribute>
      </xsl:template>
      <xsl:template match="/domain/devices/disk[@device='cdrom']/address"/>
    </xsl:stylesheet>
  XSLT

  masters = [for i in range(var.masters_count) : {
    name  = "master-${i + 1}"
    ip    = "${var.subnet}.${var.masters_first_octet + i}"
    index = i
  }]

  workers = [for i in range(var.workers_count) : {
    name  = "worker-${i + 1}"
    ip    = "${var.subnet}.${var.workers_first_octet + i}"
    index = i
  }]

  all_nodes = concat(
    [{ name = "lb", ip = local.lb_ip }],
    local.masters,
    local.workers
  )

  # /etc/hosts snippet injected via cloud-init
  hosts_entries = join("\n", [for n in local.all_nodes : "${n.ip} ${n.name}"])

  ssh_public_key = file(pathexpand(var.ssh_public_key_path))
}

# ── Storage pool ──────────────────────────────────────────────────────────────
resource "libvirt_pool" "k8s" {
  name = var.libvirt_pool
  type = "dir"

  target {
    path = "/var/lib/libvirt/images/${var.libvirt_pool}"
  }
}

# ── Network ───────────────────────────────────────────────────────────────────
resource "libvirt_network" "k8s" {
  name      = "${var.cluster_name}-net"
  mode      = "nat"
  addresses = ["${var.subnet}.0/24"]
  autostart = true

  dns {
    enabled    = true
    local_only = false
  }
}

# ── Base image volume ─────────────────────────────────────────────────────────
resource "libvirt_volume" "ubuntu_base" {
  name   = "${var.cluster_name}-ubuntu-base.qcow2"
  pool   = libvirt_pool.k8s.name
  source = var.ubuntu_image_url
  format = "qcow2"
}

# ── Helper: cloud-init user-data per node ─────────────────────────────────────
locals {
  user_data_lb = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname       = "lb"
    ssh_public_key = local.ssh_public_key
    hosts_entries  = local.hosts_entries
  })
  network_data_lb = templatefile("${path.module}/cloud-init/network-config.tpl", {
    ip      = local.lb_ip
    gateway = "${var.subnet}.1"
  })
}

# ── Load Balancer ─────────────────────────────────────────────────────────────
resource "libvirt_volume" "lb" {
  name           = "${var.cluster_name}-lb.qcow2"
  pool           = libvirt_pool.k8s.name
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
  size           = 10 * 1024 * 1024 * 1024 # 10 GiB
}

resource "libvirt_cloudinit_disk" "lb" {
  name           = "${var.cluster_name}-lb-cloudinit.iso"
  pool           = libvirt_pool.k8s.name
  user_data      = local.user_data_lb
  network_config = local.network_data_lb
}

resource "libvirt_domain" "lb" {
  name    = "${var.cluster_name}-lb"
  vcpu    = var.lb_cpus
  memory  = var.lb_memory
  machine = local.machine_type

  cpu {
    mode = "host-passthrough"
  }

  xml {
    xslt = local.cloudinit_scsi_xslt
  }

  cloudinit = libvirt_cloudinit_disk.lb.id

  network_interface {
    network_id     = libvirt_network.k8s.id
    addresses      = [local.lb_ip]
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.lb.id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }

}

# ── Masters ───────────────────────────────────────────────────────────────────
resource "libvirt_volume" "masters" {
  for_each = { for m in local.masters : m.name => m }

  name           = "${var.cluster_name}-${each.key}.qcow2"
  pool           = libvirt_pool.k8s.name
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
  size           = 50 * 1024 * 1024 * 1024 # 50 GiB
}

resource "libvirt_cloudinit_disk" "masters" {
  for_each = { for m in local.masters : m.name => m }

  name = "${var.cluster_name}-${each.key}-cloudinit.iso"
  pool = libvirt_pool.k8s.name

  user_data = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname       = each.key
    ssh_public_key = local.ssh_public_key
    hosts_entries  = local.hosts_entries
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.tpl", {
    ip      = each.value.ip
    gateway = "${var.subnet}.1"
  })
}

resource "libvirt_domain" "masters" {
  for_each = { for m in local.masters : m.name => m }

  name    = "${var.cluster_name}-${each.key}"
  vcpu    = var.masters_cpus
  memory  = var.masters_memory
  machine = local.machine_type

  cpu {
    mode = "host-passthrough"
  }

  xml {
    xslt = local.cloudinit_scsi_xslt
  }

  cloudinit = libvirt_cloudinit_disk.masters[each.key].id

  network_interface {
    network_id     = libvirt_network.k8s.id
    addresses      = [each.value.ip]
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.masters[each.key].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}

# ── Workers ───────────────────────────────────────────────────────────────────
resource "libvirt_volume" "workers" {
  for_each = { for w in local.workers : w.name => w }

  name           = "${var.cluster_name}-${each.key}.qcow2"
  pool           = libvirt_pool.k8s.name
  base_volume_id = libvirt_volume.ubuntu_base.id
  format         = "qcow2"
  size           = 50 * 1024 * 1024 * 1024 # 50 GiB
}

resource "libvirt_cloudinit_disk" "workers" {
  for_each = { for w in local.workers : w.name => w }

  name = "${var.cluster_name}-${each.key}-cloudinit.iso"
  pool = libvirt_pool.k8s.name

  user_data = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname       = each.key
    ssh_public_key = local.ssh_public_key
    hosts_entries  = local.hosts_entries
  })

  network_config = templatefile("${path.module}/cloud-init/network-config.tpl", {
    ip      = each.value.ip
    gateway = "${var.subnet}.1"
  })
}

resource "libvirt_domain" "workers" {
  for_each = { for w in local.workers : w.name => w }

  name    = "${var.cluster_name}-${each.key}"
  vcpu    = var.workers_cpus
  memory  = var.workers_memory
  machine = local.machine_type

  cpu {
    mode = "host-passthrough"
  }

  xml {
    xslt = local.cloudinit_scsi_xslt
  }

  cloudinit = libvirt_cloudinit_disk.workers[each.key].id

  network_interface {
    network_id     = libvirt_network.k8s.id
    addresses      = [each.value.ip]
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.workers[each.key].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
}
