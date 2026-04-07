resource "oci_mysql_mysql_db_system" "benchmark" {
  compartment_id      = var.compartment_id
  display_name        = "oci-mysql-benchmark"
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  shape_name          = var.mysql_shape
  subnet_id           = oci_core_subnet.private.id
  configuration_id    = oci_mysql_mysql_configuration.benchmark.id

  admin_username = "admin"
  admin_password = var.db_admin_password

  data_storage_size_in_gb = 100
  is_highly_available     = false
  crash_recovery          = "ENABLED"
  port                    = 3306
  port_x                  = 33060
}
