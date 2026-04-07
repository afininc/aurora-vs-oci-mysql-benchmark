resource "oci_core_network_security_group" "mysql" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "mysql-nsg"
}

resource "oci_core_network_security_group_security_rule" "mysql_ingress_3306" {
  network_security_group_id = oci_core_network_security_group.mysql.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = "10.1.10.0/24"
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 3306
      max = 3306
    }
  }
}

resource "oci_core_network_security_group_security_rule" "mysql_egress_all" {
  network_security_group_id = oci_core_network_security_group.mysql.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}

resource "oci_core_network_security_group" "client" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "client-nsg"
}

resource "oci_core_network_security_group_security_rule" "client_ingress_ssh" {
  network_security_group_id = oci_core_network_security_group.client.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.allowed_ssh_cidr
  source_type               = "CIDR_BLOCK"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "client_egress_all" {
  network_security_group_id = oci_core_network_security_group.client.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
}
