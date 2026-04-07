resource "oci_mysql_mysql_configuration" "benchmark" {
  compartment_id = var.compartment_id
  display_name   = "benchmark-thread-pool-config"
  shape_name     = var.mysql_shape

  variables {
    max_connections                    = 5000
    max_prepared_stmt_count            = 1048576
    innodb_buffer_pool_size            = 103079215104
    innodb_lock_wait_timeout           = 50
    long_query_time                    = 2
    thread_pool_size                   = var.thread_pool_size
    thread_pool_max_transactions_limit = var.thread_pool_max_transactions_limit
  }
}
