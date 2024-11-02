
locals {
  web_prefix = "web"
  web_labels = "node-pool=web"

  webs = { for k in flatten([
    for zone in local.zones : [
      for inx in range(lookup(try(var.instances[zone], {}), "web_count", 0)) : {
        inx : inx
        id : lookup(try(var.instances[zone], {}), "web_id", 9000) + inx
        name : "${local.web_prefix}-${format("%02d", index(local.zones, zone))}${format("%x", 10 + inx)}"
        zone : zone
        cpu : lookup(try(var.instances[zone], {}), "web_cpu", 1)
        mem : lookup(try(var.instances[zone], {}), "web_mem", 2048)

        hvv4 = cidrhost(local.subnets[zone], 0)
        ipv4 : cidrhost(local.subnets[zone], 1 + inx)
        gwv4 : cidrhost(local.subnets[zone], 0)

        ipv6ula : cidrhost(cidrsubnet(var.vpc_main_cidr[1], 16, index(local.zones, zone)), 256 + lookup(try(var.instances[zone], {}), "web_id", 9000) + inx)
        ipv6 : cidrhost(cidrsubnet(lookup(try(var.nodes[zone], {}), "ip6", "fe80::/64"), 16, 1 + index(local.zones, zone)), 256 + lookup(try(var.instances[zone], {}), "web_id", 9000) + inx)
        gwv6 : lookup(try(var.nodes[zone], {}), "gw6", "fe80::1")
      }
    ]
  ]) : k.name => k }
}

module "web_affinity" {
  for_each = { for zone in local.zones : zone => {
    zone : zone
    vms : lookup(try(var.instances[zone], {}), "web_count", 0)
  } if lookup(try(var.instances[zone], {}), "web_count", 0) > 0 }

  source       = "./cpuaffinity"
  cpu_affinity = var.nodes[each.value.zone].cpu
  vms          = each.value.vms
  cpus         = lookup(try(var.instances[each.value.zone], {}), "web_cpu", 1)
}

resource "proxmox_virtual_environment_file" "web_machineconfig" {
  for_each     = local.webs
  node_name    = each.value.zone
  content_type = "snippets"
  datastore_id = "local"

  source_raw {
    data = templatefile("${path.module}/templates/${lookup(var.instances[each.value.zone], "web_template", "worker.yaml.tpl")}",
      merge(local.kubernetes, try(var.instances["all"], {}), {
        labels      = join(",", [local.web_labels, lookup(var.instances[each.value.zone], "web_labels", "")])
        nodeSubnets = [local.subnets[each.value.zone], var.vpc_main_cidr[1]]
        lbv4        = local.lbv4
        ipv4        = each.value.ipv4
        gwv4        = each.value.gwv4
        hvv4        = each.value.hvv4
        ipv6        = "${each.value.ipv6}/64"
        gwv6        = each.value.gwv6
        kernelArgs  = []
    }))
    file_name = "${each.value.name}.yaml"
  }
}

resource "proxmox_virtual_environment_file" "web_metadata" {
  for_each     = local.webs
  node_name    = each.value.zone
  content_type = "snippets"
  datastore_id = "local"

  source_raw {
    data = templatefile("${path.module}/templates/metadata.yaml", {
      hostname : each.value.name,
      id : each.value.id,
      providerID : "proxmox://${var.region}/${each.value.id}",
      type : "${each.value.cpu}VCPU-${floor(each.value.mem / 1024)}GB",
      zone : each.value.zone,
      region : var.region,
    })
    file_name = "${each.value.name}.metadata.yaml"
  }
}

# resource "null_resource" "web_nlb_forward" {
#   for_each = { for k, v in var.instances : k => v if lookup(try(var.instances[k], {}), "web_count", 0) > 0 }
#   connection {
#     type = "ssh"
#     user = "root"
#     host = "${each.key}.${var.proxmox_domain}"
#   }

#   provisioner "file" {
#     content = jsonencode(yamldecode(templatefile("${path.module}/templates/nlb_forward.tpl", {
#       node : each.key
#       webs : local.webs
#     })))
#     destination = "/etc/ansible/facts.d/nlb_forward.fact"
#   }

#   triggers = {
#     params = filemd5("${path.module}/templates/nlb_forward.tpl")
#     webs   = md5(jsonencode([for w in local.webs : w.ipv4 if w.zone == each.key]))
#   }
# }

resource "proxmox_virtual_environment_vm" "web" {
  for_each    = local.webs
  name        = each.value.name
  node_name   = each.value.zone
  vm_id       = each.value.id
  description = "Talos web node"

  startup {
    order    = 3
    up_delay = 5
  }

  machine = "q35"
  cpu {
    architecture = "x86_64"
    cores        = each.value.cpu
    affinity     = join(",", module.web_affinity[each.value.zone].arch[each.value.inx].cpus)
    sockets      = 1
    numa         = true
    type         = "host"
  }
  memory {
    dedicated = each.value.mem
    # hugepages      = "1024"
    # keep_hugepages = true
  }
  dynamic "numa" {
    for_each = { for idx, numa in module.web_affinity[each.value.zone].arch[each.value.inx].numa : idx => {
      device = "numa${index(keys(module.web_affinity[each.value.zone].arch[each.value.inx].numa), idx)}"
      cpus   = "${index(keys(module.web_affinity[each.value.zone].arch[each.value.inx].numa), idx) * (each.value.cpu / length(module.web_affinity[each.value.zone].arch[each.value.inx].numa))}-${(index(keys(module.web_affinity[each.value.zone].arch[each.value.inx].numa), idx) + 1) * (each.value.cpu / length(module.web_affinity[each.value.zone].arch[each.value.inx].numa)) - 1}"
      mem    = each.value.mem / length(module.web_affinity[each.value.zone].arch[each.value.inx].numa)
    } }
    content {
      device    = numa.value.device
      cpus      = numa.value.cpus
      hostnodes = numa.key
      memory    = numa.value.mem
      policy    = "bind"
    }
  }

  scsi_hardware = "virtio-scsi-single"
  disk {
    datastore_id = lookup(try(var.nodes[each.value.zone], {}), "storage", "local")
    interface    = "scsi0"
    iothread     = true
    ssd          = true
    cache        = "none"
    size         = 32
    file_format  = "raw"
  }
  clone {
    vm_id = proxmox_virtual_environment_vm.template[each.value.zone].id
  }

  initialization {
    dns {
      servers = [each.value.gwv4, "2001:4860:4860::8888"]
    }
    ip_config {
      ipv6 {
        address = "${each.value.ipv6}/64"
        gateway = each.value.gwv6
      }
    }
    ip_config {
      ipv4 {
        address = "${each.value.ipv4}/24"
        gateway = each.value.hvv4
      }
      ipv6 {
        address = "${each.value.ipv6ula}/64"
      }
    }

    datastore_id      = "local"
    meta_data_file_id = proxmox_virtual_environment_file.web_metadata[each.key].id
    user_data_file_id = proxmox_virtual_environment_file.web_machineconfig[each.key].id
  }

  network_device {
    bridge      = "vmbr0"
    queues      = each.value.cpu
    mtu         = 1500
    mac_address = "32:90:${join(":", formatlist("%02X", split(".", each.value.ipv4)))}"
    firewall    = true
  }
  network_device {
    bridge   = "vmbr1"
    queues   = each.value.cpu
    mtu      = 1400
    firewall = false
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
  vga {
    type = "serial0"
  }

  lifecycle {
    ignore_changes = [
      started,
      clone,
      ipv4_addresses,
      ipv6_addresses,
      network_interface_names,
      initialization,
      disk,
      # memory,
      # numa,
    ]
  }

  tags       = [local.kubernetes["clusterName"]]
  depends_on = [proxmox_virtual_environment_file.web_machineconfig]
}

resource "proxmox_virtual_environment_firewall_options" "web" {
  for_each  = lookup(var.security_groups, "web", "") == "" ? {} : local.webs
  node_name = each.value.zone
  vm_id     = each.value.id
  enabled   = true

  dhcp          = false
  ipfilter      = false
  log_level_in  = "nolog"
  log_level_out = "nolog"
  macfilter     = false
  ndp           = true
  input_policy  = "DROP"
  output_policy = "ACCEPT"
  radv          = false

  depends_on = [proxmox_virtual_environment_vm.web]
}

resource "proxmox_virtual_environment_firewall_rules" "web" {
  for_each  = lookup(var.security_groups, "web", "") == "" ? {} : local.webs
  node_name = each.value.zone
  vm_id     = each.value.id

  rule {
    enabled        = true
    security_group = var.security_groups["web"]
  }

  depends_on = [proxmox_virtual_environment_vm.web, proxmox_virtual_environment_firewall_options.web]
}
