# ============================================================================
# atlas-terraform.tf — Terraform Configuration for MongoDB Atlas
# ============================================================================
# Provisions a MongoDB Atlas project, cluster, database user, IP access list,
# and optional search index.
#
# Usage:
#   1. Set environment variables:
#        export MONGODB_ATLAS_PUBLIC_KEY="your-public-key"
#        export MONGODB_ATLAS_PRIVATE_KEY="your-private-key"
#   2. terraform init
#   3. terraform plan -var="org_id=YOUR_ORG_ID" -var="db_password=SECRET"
#   4. terraform apply
#
# Requirements: Terraform >= 1.5, mongodbatlas provider >= 1.15
# ============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = "~> 1.15"
    }
  }
}

# --------------------------------------------------------------------------
# Variables
# --------------------------------------------------------------------------

variable "org_id" {
  description = "MongoDB Atlas Organization ID"
  type        = string
}

variable "project_name" {
  description = "Atlas project name"
  type        = string
  default     = "my-project"
}

variable "cluster_name" {
  description = "Atlas cluster name"
  type        = string
  default     = "app-cluster"
}

variable "region" {
  description = "Cloud provider region"
  type        = string
  default     = "US_EAST_1"
}

variable "cloud_provider" {
  description = "Cloud provider: AWS, GCP, or AZURE"
  type        = string
  default     = "AWS"
}

variable "cluster_tier" {
  description = "Atlas cluster tier (M0=free, M10+=dedicated)"
  type        = string
  default     = "M10"
}

variable "mongodb_version" {
  description = "MongoDB major version"
  type        = string
  default     = "7.0"
}

variable "disk_size_gb" {
  description = "Disk size in GB (M10+ only)"
  type        = number
  default     = 10
}

variable "db_username" {
  description = "Database admin username"
  type        = string
  default     = "app_admin"
}

variable "db_password" {
  description = "Database admin password"
  type        = string
  sensitive   = true
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks to allow access from"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict in production
}

variable "environment" {
  description = "Environment tag (dev, staging, production)"
  type        = string
  default     = "dev"
}

# --------------------------------------------------------------------------
# Provider
# --------------------------------------------------------------------------

provider "mongodbatlas" {
  # Credentials from environment:
  # MONGODB_ATLAS_PUBLIC_KEY and MONGODB_ATLAS_PRIVATE_KEY
}

# --------------------------------------------------------------------------
# Project
# --------------------------------------------------------------------------

resource "mongodbatlas_project" "main" {
  name   = var.project_name
  org_id = var.org_id

  tags = {
    environment = var.environment
    managed_by  = "terraform"
  }
}

# --------------------------------------------------------------------------
# Cluster
# --------------------------------------------------------------------------

resource "mongodbatlas_advanced_cluster" "main" {
  project_id   = mongodbatlas_project.main.id
  name         = var.cluster_name
  cluster_type = "REPLICASET"

  mongo_db_major_version = var.mongodb_version

  replication_specs {
    region_configs {
      provider_name = var.cloud_provider
      region_name   = var.region
      priority      = 7

      electable_specs {
        instance_size = var.cluster_tier
        node_count    = 3
        disk_size_gb  = var.disk_size_gb
      }

      auto_scaling {
        disk_gb_enabled            = true
        compute_enabled            = true
        compute_scale_down_enabled = true
        compute_min_instance_size  = var.cluster_tier
        compute_max_instance_size  = "M40"
      }
    }
  }

  # Backup
  backup_enabled = var.cluster_tier != "M0" ? true : false

  advanced_configuration {
    javascript_enabled                   = false
    minimum_enabled_tls_protocol         = "TLS1_2"
    oplog_size_mb                        = 2048
    default_read_concern                 = "majority"
    default_write_concern                = "majority"
    sample_size_bi_connector             = 1000
    no_table_scan                        = false
    oplog_min_retention_hours            = 24
    transaction_lifetime_limit_seconds   = 60
  }

  tags {
    key   = "environment"
    value = var.environment
  }

  tags {
    key   = "managed_by"
    value = "terraform"
  }
}

# --------------------------------------------------------------------------
# Database User
# --------------------------------------------------------------------------

resource "mongodbatlas_database_user" "admin" {
  project_id         = mongodbatlas_project.main.id
  auth_database_name = "admin"
  username           = var.db_username
  password           = var.db_password

  roles {
    role_name     = "readWriteAnyDatabase"
    database_name = "admin"
  }

  roles {
    role_name     = "dbAdminAnyDatabase"
    database_name = "admin"
  }

  roles {
    role_name     = "clusterMonitor"
    database_name = "admin"
  }

  scopes {
    name = mongodbatlas_advanced_cluster.main.name
    type = "CLUSTER"
  }

  labels {
    key   = "environment"
    value = var.environment
  }
}

# Read-only user for analytics
resource "mongodbatlas_database_user" "readonly" {
  project_id         = mongodbatlas_project.main.id
  auth_database_name = "admin"
  username           = "analytics_reader"
  password           = var.db_password

  roles {
    role_name     = "readAnyDatabase"
    database_name = "admin"
  }

  scopes {
    name = mongodbatlas_advanced_cluster.main.name
    type = "CLUSTER"
  }
}

# --------------------------------------------------------------------------
# Network Access (IP Whitelist)
# --------------------------------------------------------------------------

resource "mongodbatlas_project_ip_access_list" "allowed" {
  for_each   = toset(var.allowed_cidr_blocks)
  project_id = mongodbatlas_project.main.id
  cidr_block = each.value
  comment    = "Terraform managed - ${var.environment}"
}

# --------------------------------------------------------------------------
# Atlas Search Index (Optional)
# --------------------------------------------------------------------------

resource "mongodbatlas_search_index" "product_search" {
  project_id   = mongodbatlas_project.main.id
  cluster_name = mongodbatlas_advanced_cluster.main.name
  database     = "app"
  collection_name = "products"
  name         = "product_search"
  type         = "search"

  fields = jsonencode([
    {
      "type" : "string",
      "path" : "name",
      "analyzer" : "lucene.english"
    },
    {
      "type" : "string",
      "path" : "description",
      "analyzer" : "lucene.english"
    },
    {
      "type" : "number",
      "path" : "price"
    },
    {
      "type" : "token",
      "path" : "category"
    }
  ])
}

# --------------------------------------------------------------------------
# Alerts (Optional)
# --------------------------------------------------------------------------

resource "mongodbatlas_alert_configuration" "high_connections" {
  project_id = mongodbatlas_project.main.id
  enabled    = true
  event_type = "OUTSIDE_METRIC_THRESHOLD"

  metric_threshold_config {
    metric_name = "CONNECTIONS"
    operator    = "GREATER_THAN"
    threshold   = 500
    units       = "RAW"
    mode        = "AVERAGE"
  }

  notification {
    type_name     = "GROUP"
    interval_min  = 15
    delay_min     = 0
    sms_enabled   = false
    email_enabled = true
    roles         = ["GROUP_OWNER"]
  }
}

resource "mongodbatlas_alert_configuration" "replication_lag" {
  project_id = mongodbatlas_project.main.id
  enabled    = true
  event_type = "OUTSIDE_METRIC_THRESHOLD"

  metric_threshold_config {
    metric_name = "OPLOG_REPLICATION_LAG_TIME"
    operator    = "GREATER_THAN"
    threshold   = 30
    units       = "SECONDS"
    mode        = "AVERAGE"
  }

  notification {
    type_name     = "GROUP"
    interval_min  = 5
    delay_min     = 0
    sms_enabled   = false
    email_enabled = true
    roles         = ["GROUP_OWNER"]
  }
}

# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------

output "project_id" {
  description = "Atlas Project ID"
  value       = mongodbatlas_project.main.id
}

output "cluster_id" {
  description = "Atlas Cluster ID"
  value       = mongodbatlas_advanced_cluster.main.cluster_id
}

output "connection_string_srv" {
  description = "SRV connection string"
  value       = mongodbatlas_advanced_cluster.main.connection_strings[0].standard_srv
  sensitive   = true
}

output "cluster_state" {
  description = "Cluster state"
  value       = mongodbatlas_advanced_cluster.main.state_name
}
