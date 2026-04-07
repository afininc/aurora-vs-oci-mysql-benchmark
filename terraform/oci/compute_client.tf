resource "oci_core_instance" "benchmark_client" {
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  compartment_id      = var.compartment_id
  display_name        = "mysql-benchmark-client"
  shape               = "VM.Standard.E4.Flex"

  shape_config {
    ocpus         = 16
    memory_in_gbs = 32
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu.images[0].id
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.client.id]
  }

  metadata = {
    ssh_authorized_keys = tls_private_key.benchmark.public_key_openssh
  }
}
