resource "aws_rds_cluster_parameter_group" "benchmark" {
  name   = "aurora-mysql-benchmark-cluster"
  family = "aurora-mysql8.0"

  parameter {
    name         = "binlog_format"
    value        = "ROW"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_prepared_stmt_count"
    value        = "1048576"
    apply_method = "immediate"
  }
}

resource "aws_db_parameter_group" "benchmark" {
  name   = "aurora-mysql-benchmark-instance"
  family = "aurora-mysql8.0"

  parameter {
    name         = "max_connections"
    value        = "5000"
    apply_method = "immediate"
  }

  parameter {
    name         = "innodb_buffer_pool_size"
    value        = "{DBInstanceClassMemory*3/4}"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "innodb_lock_wait_timeout"
    value        = "50"
    apply_method = "immediate"
  }

  parameter {
    name         = "long_query_time"
    value        = "2"
    apply_method = "immediate"
  }

  parameter {
    name         = "slow_query_log"
    value        = "1"
    apply_method = "immediate"
  }
}
