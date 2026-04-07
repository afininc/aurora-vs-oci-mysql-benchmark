resource "tls_private_key" "benchmark" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.benchmark.private_key_pem
  filename        = "${path.module}/../../.keys/oci_benchmark.pem"
  file_permission = "0600"
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.ssh_private_key.filename
}
