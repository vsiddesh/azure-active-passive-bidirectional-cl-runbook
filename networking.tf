locals {
  primary_cluster_dns = regex("^(?:SASL_SSL://)?([^:/]+)", data.confluent_kafka_cluster.primary.bootstrap_endpoint)[0]
}

resource "azurerm_resource_group" "proxyrg" {
  name     = "rg-nginx-${var.prefix}"
  location = var.azure_region
  tags = {
    "owner_email" = "svyavahare@confluent.io"
  }
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.proxyrg.location
  resource_group_name = azurerm_resource_group.proxyrg.name
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_subnet" "internal" {
  name                 = "internal"
  resource_group_name  = azurerm_resource_group.proxyrg.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}
resource "azurerm_public_ip" "pubicip" {
  name                = "proxy-public-ip"
  resource_group_name = azurerm_resource_group.proxyrg.name
  location            = azurerm_resource_group.proxyrg.location
  allocation_method   = "Static"
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_network_interface" "main" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.proxyrg.location
  resource_group_name = azurerm_resource_group.proxyrg.name

  ip_configuration {
    name                          = "testconfiguration1"
    subnet_id                     = azurerm_subnet.internal.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pubicip.id
    # network_security_group_id     = azurerm_network_security_group.nsg.id
  }
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_subnet_network_security_group_association" "nsg" {
  subnet_id                 = azurerm_subnet.internal.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_interface_security_group_association" "nsg" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_network_security_group" "nsg" {
  name                = "vm-nsg"
  location            = azurerm_resource_group.proxyrg.location
  resource_group_name = azurerm_resource_group.proxyrg.name

  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-port-9092"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9092"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                   = "Allow-SSH"
    priority               = 100
    direction              = "Inbound"
    access                 = "Allow"
    protocol               = "Tcp"
    source_port_range      = "*"
    destination_port_range = "22"
    #source_address_prefix      = "YOUR_TERRAFORM_HOST_IP"  # Replace with your IP
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_virtual_machine" "main" {
  name                  = "${var.prefix}-vm"
  location              = azurerm_resource_group.proxyrg.location
  resource_group_name   = azurerm_resource_group.proxyrg.name
  network_interface_ids = [azurerm_network_interface.main.id]
  vm_size               = "Standard_DS1_v2"

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
  storage_os_disk {
    name              = "myosdisk1"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }
  os_profile {
    computer_name  = "hostname"
    admin_username = var.admin_username
    admin_password = var.admin_password
  }
  os_profile_linux_config {
    disable_password_authentication = false
  }
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "null_resource" "nginx_install" {
  depends_on = [azurerm_virtual_machine.main]

  provisioner "remote-exec" {
    inline = [
      "sudo apt update",
      "sudo apt install -y nginx"
    ]

    connection {
      type     = "ssh"
      host     = azurerm_public_ip.pubicip.ip_address
      user     = var.admin_username
      password = var.admin_password
      timeout  = "1m"
    }
  }

  triggers = {
    always_run = "${timestamp()}"
  }

  provisioner "file" {
    source      = "nginx.conf"      # Path to your local nginx.conf
    destination = "/tmp/nginx.conf" # Destination on the remote server
    connection {
      type     = "ssh"
      host     = azurerm_public_ip.pubicip.ip_address
      user     = var.admin_username
      password = var.admin_password
      timeout  = "1m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo nginx -t",
      "sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf",
      "if [ '${var.cc_failover_primary}' = true ]; then",
      "sudo sed -i 's/PRIMARY_HOSTNAME/${local.primary_cluster_dns}/g' /etc/nginx/nginx.conf ", # Replace with your package for production
      "fi",
      "sudo nginx -t",
      "sudo systemctl reload nginx"
    ]
    connection {
      type     = "ssh"
      host     = azurerm_public_ip.pubicip.ip_address
      user     = var.admin_username
      password = var.admin_password
      timeout  = "2m"
    }
  }

}




