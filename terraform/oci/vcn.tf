# VCN
resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "benchmark-vcn"
  dns_label      = "benchmarkvcn"
}

# Internet Gateway (for public subnet)
resource "oci_core_internet_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "benchmark-igw"
  enabled        = true
}

# Service Gateway (for OCI services from private subnet)
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "main" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "benchmark-sgw"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }
}

# Route Table — Public (via Internet Gateway)
resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }
}

# Route Table — Private (via Service Gateway)
resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "private-rt"

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }
}

# Security List for private subnet (MySQL MDS)
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.main.id
  display_name   = "private-mysql-sl"

  ingress_security_rules {
    protocol = "6"
    source   = "10.1.10.0/24"

    tcp_options {
      min = 3306
      max = 3306
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "10.1.10.0/24"

    tcp_options {
      min = 33060
      max = 33060
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

# Private Subnet — MySQL MDS
resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = "10.1.1.0/24"
  display_name               = "private-subnet-mysql"
  dns_label                  = "privatemysql"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
}

# Public Subnet — Benchmark Client
resource "oci_core_subnet" "public" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.main.id
  cidr_block        = "10.1.10.0/24"
  display_name      = "public-subnet-client"
  dns_label         = "publicclient"
  route_table_id    = oci_core_route_table.public.id
  security_list_ids = [oci_core_vcn.main.default_security_list_id]
}
