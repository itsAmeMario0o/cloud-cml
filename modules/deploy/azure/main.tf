#
# This file is part of Cisco Modeling Labs
# Copyright (c) 2019-2025, Cisco Systems, Inc.
# All rights reserved.
#

locals {
  # late binding required as the token is only known within the module
  vars = templatefile("${path.module}/../data/vars.sh", {
    cfg = merge(
      var.options.cfg,
      { sas_token = data.azurerm_storage_account_sas.cml.sas }
    )
    }
  )

  cml_config_controller = templatefile("${path.module}/../data/virl2-base-config.yml", {
    hostname      = var.options.cfg.common.controller_hostname,
    is_controller = true
    is_compute    = !var.options.cfg.cluster.enable_cluster || var.options.cfg.cluster.allow_vms_on_controller
    cfg = merge(
      var.options.cfg,
      { sas_token = data.azurerm_storage_account_sas.cml.sas }
    )
    }
  )

  # Ensure there's no tabs in the template file! Also ensure that the list of
  # reference platforms has no single quotes in the file names or keys (should
  # be reasonable, but you never know...)
  cloud_config = templatefile("${path.module}/../data/cloud-config.txt", {
    vars          = local.vars
    cml_config    = local.cml_config_controller
    cfg           = var.options.cfg
    cml           = var.options.cml
    common        = var.options.common
    copyfile      = var.options.copyfile
    del           = var.options.del
    interface_fix = var.options.interface_fix
    license       = var.options.license
    extras        = var.options.extras
    hostname      = var.options.cfg.common.controller_hostname
    path          = path.module
  })

  # vmname     = "cml-${var.options.rand_id}"
}

# this references an existing resource group
data "azurerm_resource_group" "cml" {
  name = var.options.cfg.azure.resource_group
}

# this references an existing storage account within the resource group
data "azurerm_storage_account" "cml" {
  name                = var.options.cfg.azure.storage_account
  resource_group_name = data.azurerm_resource_group.cml.name
}

data "azurerm_storage_account_sas" "cml" {
  connection_string = data.azurerm_storage_account.cml.primary_connection_string
  https_only        = true
  signed_version    = "2022-11-02"

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  start = timestamp()
  # azure-lab fork: one hour is not enough for a large refplat selection over
  # a busy link. Default four hours, overridable per build. ADR 0001.
  expiry = timeadd(timestamp(), try(var.options.cfg.azure.sas_validity, "4h"))

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = true
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

resource "azurerm_network_security_group" "cml" {
  name                = "cml-sg-${var.options.rand_id}"
  location            = data.azurerm_resource_group.cml.location
  resource_group_name = data.azurerm_resource_group.cml.name
}

resource "azurerm_network_security_rule" "cml_std" {
  name                        = "cml-std-in"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = [80, 443, 1122]
  source_address_prefixes     = var.options.cfg.common.allowed_ipv4_subnets_cml2
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}

resource "azurerm_network_security_rule" "cml_admin" {
  name                        = "cml-admin-in"
  priority                    = 150
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = [22, 9090]
  source_address_prefixes     = var.options.cfg.common.allowed_ipv4_subnets_mgmt
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}

resource "azurerm_network_security_rule" "cml_patty_tcp" {
  count             = var.options.cfg.common.enable_patty ? 1 : 0
  name              = "patty-tcp-in"
  priority          = 200
  direction         = "Inbound"
  access            = "Allow"
  protocol          = "Tcp"
  source_port_range = "*"
  # destination_port_range      = "2000-7999"
  # Policy disallows 3389, 5500, 5800 and 5900 :(
  # destination_port_ranges     = ["2000-3388", "3340-5499", "5501-5799", "5801-5899", "5901-7999"]
  destination_port_range      = "2000-2999"
  source_address_prefixes     = var.options.cfg.common.allowed_ipv4_subnets_cml2
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}

resource "azurerm_network_security_rule" "cml_patty_udp" {
  count             = var.options.cfg.common.enable_patty ? 1 : 0
  name              = "patty-udp-in"
  priority          = 300
  direction         = "Inbound"
  access            = "Allow"
  protocol          = "Udp"
  source_port_range = "*"
  # destination_port_range      = "2000-7999"
  # Policy disallows 3389, 5500, 5800 and 5900 :(
  # destination_port_ranges     = ["2000-3388", "3340-5499", "5501-5799", "5801-5899", "5901-7999"]
  destination_port_range      = "2000-2999"
  source_address_prefixes     = var.options.cfg.common.allowed_ipv4_subnets_cml2
  destination_address_prefix  = "*"
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}

# azure-lab fork: ISE and FTD in the apps subnet reach lab prefixes through
# this host. The NSG sits on the NIC and sees the forwarded packet's real
# destination, which is a lab address, hence the summary as destination.
# ADR 0003.
resource "azurerm_network_security_rule" "lab_transit" {
  count                       = try(var.options.cfg.azure.apps_subnet_cidr, "") != "" ? 1 : 0
  name                        = "lab-transit-in"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.options.cfg.azure.apps_subnet_cidr
  destination_address_prefix  = try(var.options.cfg.azure.lab_summary_cidr, "10.100.0.0/16")
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}

# azure-lab fork: the public IP is owned by the persistent root so the
# address, and the cml-mcp config that points at it, survive a rebuild.
# ADR 0003.
data "azurerm_public_ip" "cml" {
  name                = var.options.cfg.azure.public_ip_name
  resource_group_name = data.azurerm_resource_group.cml.name
}

# azure-lab fork: the VNet and subnet are owned by the persistent root in
# cml-azure-lab so they survive a rebuild. Upstream created them here with a
# hardcoded 10.0.0.0/16. ADR 0001.
data "azurerm_virtual_network" "cml" {
  name                = var.options.cfg.azure.vnet_name
  resource_group_name = data.azurerm_resource_group.cml.name
}

data "azurerm_subnet" "cml" {
  name                 = var.options.cfg.azure.subnet_name
  virtual_network_name = data.azurerm_virtual_network.cml.name
  resource_group_name  = data.azurerm_resource_group.cml.name
}

resource "azurerm_network_interface" "cml" {
  name                = "cml-nic-${var.options.rand_id}"
  location            = data.azurerm_resource_group.cml.location
  resource_group_name = data.azurerm_resource_group.cml.name

  # azure-lab fork: the CML host forwards between the lab transit network and
  # the VNet. Azure drops forwarded packets unless this is on. Accelerated
  # networking is free on E-series sizes and helps the image copy. ADR 0003.
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true

  ip_configuration {
    name      = "internal"
    subnet_id = data.azurerm_subnet.cml.id
    # azure-lab fork: static, because the Azure route table for the lab
    # summary names this address as its next hop. ADR 0003.
    private_ip_address_allocation = "Static"
    private_ip_address            = var.options.cfg.azure.private_ip
    public_ip_address_id          = data.azurerm_public_ip.cml.id
  }
}

# Connect the security group to the network interface
resource "azurerm_network_interface_security_group_association" "cml" {
  network_interface_id      = azurerm_network_interface.cml.id
  network_security_group_id = azurerm_network_security_group.cml.id
}

resource "azurerm_linux_virtual_machine" "cml" {
  name                = var.options.cfg.common.controller_hostname
  resource_group_name = data.azurerm_resource_group.cml.name
  location            = data.azurerm_resource_group.cml.location

  # size                = "Standard_F2"
  # https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization
  # https://learn.microsoft.com/en-us/azure/virtual-machines/dv5-dsv5-series
  # Size	vCPU	Memory: GiB	Temp storage (SSD) GiB	Max data disks	Max NICs	Max network bandwidth (Mbps)
  # Standard_D2_v5	2	8	Remote Storage Only	4	2	12500
  # Standard_D4_v5	4	16	Remote Storage Only	8	2	12500
  # Standard_D8_v5	8	32	Remote Storage Only	16	4	12500
  # Standard_D16_v5	16	64	Remote Storage Only	32	8	12500
  # Standard_D32_v5	32	128	Remote Storage Only	32	8	16000
  # Standard_D48_v5	48	192	Remote Storage Only	32	8	24000
  # Standard_D64_v5	64	256	Remote Storage Only	32	8	30000
  # Standard_D96_v5	96	384	Remote Storage Only	32	8	35000
  #
  # https://learn.microsoft.com/en-us/azure/virtual-machines/ddv4-ddsv4-series
  # Size	vCPU	Memory: GiB	Temp storage (SSD) GiB	Max data disks	Max temp storage throughput: IOPS/MBps*	Max NICs	Expected network bandwidth (Mbps)
  # Standard_D2d_v41	2	8	75  	4	9000/125	2	5000
  # Standard_D4d_v4     4	16	150 	8	19000/250	2	10000
  # Standard_D8d_v4     8	32	300 	16	38000/500	4	12500
  # Standard_D16d_v4	16	64	600 	32	75000/1000	8	12500
  # Standard_D32d_v4	32	128	1200	32	150000/2000	8	16000
  # Standard_D48d_v4	48	192	1800	32	225000/3000	8	24000
  # Standard_D64d_v4	64	256	2400	32	300000/4000	8	30000

  size = var.options.cfg.azure.size

  # azure-lab fork: optional spot pricing. Deallocate on eviction so the OS
  # disk and the attached data disk survive; the next 20-up.sh rebuilds.
  # max_bid_price -1 means "up to the on-demand price". ADR 0001.
  priority        = try(var.options.cfg.azure.spot.enabled, false) ? "Spot" : "Regular"
  eviction_policy = try(var.options.cfg.azure.spot.enabled, false) ? "Deallocate" : null
  max_bid_price   = try(var.options.cfg.azure.spot.enabled, false) ? try(var.options.cfg.azure.spot.max_bid_price, -1) : null

  # uncomment this block for diagnostics and serial console access to the VM
  # boot_diagnostics {
  # }

  admin_username = "ubuntu"
  network_interface_ids = [
    azurerm_network_interface.cml.id,
  ]

  admin_ssh_key {
    username   = "ubuntu"
    public_key = data.azurerm_ssh_public_key.cml.public_key
    # public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching = "ReadWrite"
    # azure-lab fork: Standard_LRS is too slow for a 200 GB disk full of
    # qcow2 images. Premium needs an "s" size, which the spec mandates. ADR 0001.
    storage_account_type = try(var.options.cfg.azure.os_disk_type, "Premium_LRS")
    disk_size_gb         = var.options.cfg.common.disk_size
  }

  # https://canonical-azure.readthedocs-hosted.com/en/latest/azure-explanation/daily-vs-release-images/
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "minimal"
    version   = "latest"
  }

  custom_data = data.cloudinit_config.azure_ud.rendered
}

# azure-lab fork: attach the persistent data disk. It is created and kept by
# the persistent root; this only attaches it. LUN 0 is what the provisioning
# hook 05-persist.sh waits for at /dev/disk/azure/scsi1/lun0. ADR 0002.
resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count              = try(var.options.cfg.azure.data_disk_id, "") != "" ? 1 : 0
  managed_disk_id    = var.options.cfg.azure.data_disk_id
  virtual_machine_id = azurerm_linux_virtual_machine.cml.id
  lun                = 0
  caching            = "ReadOnly"
}

data "azurerm_ssh_public_key" "cml" {
  name                = var.options.cfg.common.key_name
  resource_group_name = data.azurerm_resource_group.cml.name
}

data "cloudinit_config" "azure_ud" {
  gzip          = true
  base64_encode = true # always true if gzip is true

  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"

    content = local.cloud_config
  }
}
