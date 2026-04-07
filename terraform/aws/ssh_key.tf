resource "tls_private_key" "benchmark" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "benchmark" {
  key_name   = "aurora-benchmark-key"
  public_key = tls_private_key.benchmark.public_key_openssh
}

resource "local_file" "ssh_private_key" {
  content         = tls_private_key.benchmark.private_key_pem
  filename        = "${path.module}/../../.keys/aws_benchmark.pem"
  file_permission = "0600"
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.ssh_private_key.filename
}
