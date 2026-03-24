# Terraform module for Google Cloud Run service
#
# Usage:
#   module "cloud_run" {
#     source       = "./modules/cloud-run"
#     project_id   = "my-project"
#     region       = "us-central1"
#     service_name = "my-api"
#     image        = "us-central1-docker.pkg.dev/my-project/repo/app:v1"
#   }
#
# Customize variables below for your deployment.

# ============================================================
# Variables
# ============================================================

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "Cloud Run region"
  type        = string
  default     = "us-central1"
}

variable "service_name" {
  description = "Cloud Run service name"
  type        = string
}

variable "image" {
  description = "Container image URL"
  type        = string
}

variable "port" {
  description = "Container port"
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "CPU limit (1, 2, 4, or 8)"
  type        = string
  default     = "1"
}

variable "memory" {
  description = "Memory limit (e.g., 512Mi, 1Gi, 2Gi)"
  type        = string
  default     = "512Mi"
}

variable "min_instances" {
  description = "Minimum number of instances"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Maximum number of instances"
  type        = number
  default     = 100
}

variable "concurrency" {
  description = "Maximum concurrent requests per instance"
  type        = number
  default     = 80
}

variable "timeout" {
  description = "Request timeout in seconds"
  type        = number
  default     = 300
}

variable "cpu_idle" {
  description = "Throttle CPU between requests (true=request-based, false=always-on)"
  type        = bool
  default     = true
}

variable "startup_cpu_boost" {
  description = "Enable startup CPU boost"
  type        = bool
  default     = true
}

variable "env_vars" {
  description = "Environment variables map"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Secret Manager secrets: {ENV_NAME = {secret = 'secret-id', version = 'latest'}}"
  type = map(object({
    secret  = string
    version = string
  }))
  default = {}
}

variable "allow_unauthenticated" {
  description = "Allow public access"
  type        = bool
  default     = false
}

variable "service_account_email" {
  description = "Service account email (leave empty for default)"
  type        = string
  default     = ""
}

variable "vpc_network" {
  description = "VPC network ID for Direct VPC egress (optional)"
  type        = string
  default     = ""
}

variable "vpc_subnet" {
  description = "VPC subnet ID for Direct VPC egress (optional)"
  type        = string
  default     = ""
}

variable "vpc_egress" {
  description = "VPC egress setting: ALL_TRAFFIC or PRIVATE_RANGES_ONLY"
  type        = string
  default     = "ALL_TRAFFIC"
}

variable "cloudsql_instances" {
  description = "List of Cloud SQL instance connection names"
  type        = list(string)
  default     = []
}

variable "ingress" {
  description = "Ingress setting: INGRESS_TRAFFIC_ALL, INGRESS_TRAFFIC_INTERNAL_ONLY, INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "labels" {
  description = "Labels to apply to the service"
  type        = map(string)
  default     = {}
}

# ============================================================
# Service Account (optional — create if not provided)
# ============================================================

resource "google_service_account" "cloud_run" {
  count        = var.service_account_email == "" ? 1 : 0
  project      = var.project_id
  account_id   = "${var.service_name}-sa"
  display_name = "Cloud Run SA for ${var.service_name}"
}

locals {
  service_account_email = var.service_account_email != "" ? var.service_account_email : google_service_account.cloud_run[0].email
}

# ============================================================
# Cloud Run Service
# ============================================================

resource "google_cloud_run_v2_service" "main" {
  name     = var.service_name
  location = var.region
  project  = var.project_id
  ingress  = var.ingress
  labels   = var.labels

  template {
    service_account = local.service_account_email
    timeout         = "${var.timeout}s"
    max_instance_request_concurrency = var.concurrency

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = var.cpu_idle
        startup_cpu_boost = var.startup_cpu_boost
      }

      # Environment variables
      dynamic "env" {
        for_each = var.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      # Secrets
      dynamic "env" {
        for_each = var.secrets
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value.secret
              version = env.value.version
            }
          }
        }
      }

      # Health probes
      startup_probe {
        http_get {
          path = "/healthz"
          port = var.port
        }
        initial_delay_seconds = 0
        period_seconds        = 2
        failure_threshold     = 15
        timeout_seconds       = 3
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = var.port
        }
        period_seconds    = 30
        failure_threshold = 3
        timeout_seconds   = 5
      }
    }

    # VPC access (Direct VPC egress)
    dynamic "vpc_access" {
      for_each = var.vpc_network != "" ? [1] : []
      content {
        network_interfaces {
          network    = var.vpc_network
          subnetwork = var.vpc_subnet
        }
        egress = var.vpc_egress
      }
    }

    # Cloud SQL connections
    dynamic "volumes" {
      for_each = length(var.cloudsql_instances) > 0 ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = var.cloudsql_instances
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

# ============================================================
# IAM — Public access (optional)
# ============================================================

resource "google_cloud_run_v2_service_iam_member" "public" {
  count    = var.allow_unauthenticated ? 1 : 0
  name     = google_cloud_run_v2_service.main.name
  location = google_cloud_run_v2_service.main.location
  project  = var.project_id
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ============================================================
# Outputs
# ============================================================

output "service_url" {
  description = "Cloud Run service URL"
  value       = google_cloud_run_v2_service.main.uri
}

output "service_name" {
  description = "Cloud Run service name"
  value       = google_cloud_run_v2_service.main.name
}

output "latest_revision" {
  description = "Latest ready revision name"
  value       = google_cloud_run_v2_service.main.latest_ready_revision
}

output "service_account_email" {
  description = "Service account email used by the service"
  value       = local.service_account_email
}
