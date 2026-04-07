#!/usr/bin/tclsh
# HammerDB TPC-C Benchmark Run Script
# Runs timed TPC-C workload with configurable VU count.
# Required env: DB_HOST, DB_PASSWORD, VU_COUNT
# Optional env: DB_PORT (3306), DB_USER (admin)

proc getenv {name {default ""}} {
    if {[info exists ::env($name)]} {
        return $::env($name)
    }
    if {$default eq ""} {
        puts "ERROR: Required environment variable $name is not set"
        exit 1
    }
    return $default
}

set db_host     [getenv DB_HOST]
set db_port     [getenv DB_PORT 3306]
set db_user     [getenv DB_USER admin]
set db_password [getenv DB_PASSWORD]
set vu_count    [getenv VU_COUNT]

puts "=== HammerDB TPC-C Run ==="
puts "Host: $db_host:$db_port  User: $db_user  VUs: $vu_count"
puts "Rampup: 2 min  Duration: 10 min"

dbset db mysql
dbset bm TPC-C

diset connection mysql_host $db_host
diset connection mysql_port $db_port

diset tpcc mysql_user     $db_user
diset tpcc mysql_pass     $db_password
diset tpcc mysql_driver   timed
diset tpcc mysql_rampup   2
diset tpcc mysql_duration 10

vuset vu $vu_count
vucreate
vurun
waittocomplete

puts "=== TPC-C run complete (VUs: $vu_count) ==="
