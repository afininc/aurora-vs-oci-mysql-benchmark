output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (for Aurora DB subnet group)"
  value       = [aws_subnet.private_a.id, aws_subnet.private_c.id]
}

output "public_subnet_id" {
  description = "Public subnet ID (for benchmark client EC2)"
  value       = aws_subnet.public.id
}

output "aurora_sg_id" {
  description = "Security group ID for Aurora MySQL cluster"
  value       = aws_security_group.aurora.id
}

output "client_sg_id" {
  description = "Security group ID for benchmark client EC2"
  value       = aws_security_group.client.id
}

output "db_subnet_group_name" {
  description = "DB subnet group name for Aurora cluster"
  value       = aws_db_subnet_group.aurora.name
}

output "cluster_endpoint" {
  description = "Aurora cluster writer endpoint"
  value       = aws_rds_cluster.benchmark.endpoint
}

output "reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.benchmark.reader_endpoint
}

output "cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.benchmark.port
}

output "client_public_ip" {
  description = "Public IP of the benchmark client EC2 instance"
  value       = aws_instance.benchmark_client.public_ip
}

output "client_instance_id" {
  description = "Instance ID of the benchmark client EC2 instance"
  value       = aws_instance.benchmark_client.id
}
