resource "aws_rds_cluster" "benchmark" {
  cluster_identifier              = "aurora-mysql-benchmark"
  engine                          = "aurora-mysql"
  engine_version                  = "8.0.mysql_aurora.3.08.0"
  database_name                   = "benchmark"
  master_username                 = var.db_username
  master_password                 = var.db_password
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.benchmark.name
  skip_final_snapshot             = true
  backup_retention_period         = 1
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  storage_encrypted               = true
}

resource "aws_rds_cluster_instance" "benchmark" {
  count                        = 1
  identifier                   = "aurora-mysql-benchmark-1"
  cluster_identifier           = aws_rds_cluster.benchmark.id
  instance_class               = "db.r6g.4xlarge"
  engine                       = aws_rds_cluster.benchmark.engine
  engine_version               = aws_rds_cluster.benchmark.engine_version
  db_parameter_group_name      = aws_db_parameter_group.benchmark.name
  publicly_accessible          = false
  performance_insights_enabled = true
}
