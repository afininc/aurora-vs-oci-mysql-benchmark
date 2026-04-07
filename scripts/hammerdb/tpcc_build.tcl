#!/usr/bin/tclsh
# HammerDB TPC-C Schema Build Script
# Builds 100-warehouse (~10GB) TPC-C schema on MySQL target.
# Required env: DB_HOST, DB_PASSWORD
# Optional env: DB_PORT (3306), DB_USER (admin)

proc getenv {name {default ""}} {
    if {[info exists ::env($name)]} {
        return $::env($name)
    }
    if {$default eq "" && $name ne "DB_PORT" && $name ne "DB_USER"} {
        puts "ERROR: Required environment variable $name is not set"
        exit 1
    }
    return $default
}

set db_host     [getenv DB_HOST]
set db_port     [getenv DB_PORT 3306]
set db_user     [getenv DB_USER admin]
set db_password [getenv DB_PASSWORD]

puts "=== HammerDB TPC-C Schema Build ==="
puts "Host: $db_host:$db_port  User: $db_user  Warehouses: 100"

dbset db mysql
dbset bm TPC-C

diset connection mysql_host $db_host
diset connection mysql_port $db_port

diset tpcc mysql_user      $db_user
diset tpcc mysql_pass      $db_password
diset tpcc mysql_count_ware 100
diset tpcc mysql_num_vu    16
diset tpcc mysql_driver    timed
diset tpcc mysql_rampup    0
diset tpcc mysql_duration  1

buildschema
waittocomplete

puts "=== Schema build complete ==="
