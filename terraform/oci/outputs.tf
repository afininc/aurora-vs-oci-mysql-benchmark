output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.main.id
}

output "private_subnet_id" {
  description = "OCID of the private subnet (MySQL MDS)"
  value       = oci_core_subnet.private.id
}

output "public_subnet_id" {
  description = "OCID of the public subnet (benchmark client)"
  value       = oci_core_subnet.public.id
}

output "mysql_nsg_id" {
  description = "OCID of the MySQL NSG"
  value       = oci_core_network_security_group.mysql.id
}

output "client_nsg_id" {
  description = "OCID of the client NSG"
  value       = oci_core_network_security_group.client.id
}

output "client_public_ip" {
  description = "Public IP of the benchmark client instance"
  value       = oci_core_instance.benchmark_client.public_ip
}

output "client_instance_id" {
  description = "OCID of the benchmark client instance"
  value       = oci_core_instance.benchmark_client.id
}

output "db_system_id" {
  description = "OCID of the MySQL MDS DB system"
  value       = oci_mysql_mysql_db_system.benchmark.id
}

output "db_endpoint" {
  description = "Endpoints of the MySQL MDS DB system"
  value       = oci_mysql_mysql_db_system.benchmark.endpoints
}

output "db_port" {
  description = "Port of the MySQL MDS DB system"
  value       = oci_mysql_mysql_db_system.benchmark.port
}
