variable "tenancy_ocid" {
  description = "OCID of the tenancy"
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API key"
  type        = string
}

variable "private_key_path" {
  description = "Path to the private API key file"
  type        = string
}

variable "region" {
  description = "OCI region"
  type        = string
  default     = "ap-seoul-1"
}

variable "compartment_id" {
  description = "OCID of the compartment"
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.1.0.0/16"
}

variable "db_admin_password" {
  description = "Admin password for MySQL MDS"
  type        = string
  sensitive   = true
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the benchmark client"
  type        = string
  default     = "0.0.0.0/0"
}

variable "mysql_shape" {
  description = "Shape for MySQL MDS DB system and configuration"
  type        = string
  default     = "MySQL.16"
}

variable "thread_pool_size" {
  description = "MySQL thread pool size"
  type        = number
  default     = 16
}

variable "thread_pool_max_transactions_limit" {
  description = "MySQL thread pool max transactions limit"
  type        = number
  default     = 512
}
