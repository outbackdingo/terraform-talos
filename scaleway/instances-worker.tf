
locals {
  worker_labels = "topology.kubernetes.io/region=fr-par,topology.kubernetes.io/zone=${var.regions[0]},project.io/node-pool=worker"
}

resource "scaleway_instance_server" "worker" {
  count             = lookup(var.instances, "worker_count", 0)
  name              = "worker-${count.index + 1}"
  image             = data.scaleway_instance_image.talos.id
  type              = lookup(var.instances, "worker_type", "DEV1-M")
  enable_ipv6       = true
  enable_dynamic_ip = false
  security_group_id = scaleway_instance_security_group.worker.id
  tags              = concat(var.tags, ["worker"])

  private_network {
    pn_id = scaleway_vpc_private_network.main.id
  }

  user_data = {
    cloud-init = templatefile("${path.module}/templates/worker.yaml.tpl",
      merge(var.kubernetes, {
        name        = "worker-${count.index + 1}"
        ipv4_vip    = local.ipv4_vip
        ipv4        = cidrhost(local.main_subnet, 31 + count.index)
        ipv4_gw     = cidrhost(local.main_subnet, 1)
        clusterDns  = cidrhost(split(",", var.kubernetes["serviceSubnets"])[0], 10)
        nodeSubnets = local.main_subnet
        labels      = "${local.worker_labels},node.kubernetes.io/instance-type=${lookup(var.instances, "worker_type", "DEV1-M")}"
      })
    )
  }

  lifecycle {
    ignore_changes = [
      image,
      type,
      user_data,
    ]
  }
}

resource "scaleway_vpc_public_gateway_dhcp_reservation" "worker" {
  count              = lookup(var.instances, "worker_count", 0)
  gateway_network_id = scaleway_vpc_gateway_network.main.id
  mac_address        = scaleway_instance_server.worker[count.index].private_network.0.mac_address
  ip_address         = cidrhost(local.main_subnet, 31 + count.index)
}
