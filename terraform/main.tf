terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
    neon = {
      source  = "kislerdm/neon"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "neon" {
  api_key = var.neon_api_key
}

# Data source to get the project number
data "google_project" "project" {
  project_id = var.gcp_project_id
}

# --- Services --- #
resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  service            = "cloudresourcemanager.googleapis.com" # Added during manual deployment
  disable_on_destroy = false
}

# --- Artifact Registry --- #
resource "google_artifact_registry_repository" "n8n_repo" {
  project       = var.gcp_project_id
  location      = var.gcp_region
  repository_id = var.artifact_repo_name
  description   = "Repository for n8n workflow images"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

# --- Neon Database --- #
resource "neon_project" "n8n_db" {
  org_id     = var.neon_org_id
  name       = "n8n_db"
  pg_version = 17
  region_id  = var.neon_region  # https://neon.com/docs/introduction/regions

  # Configure default branch settings
  branch {
    name          = "production"
    database_name = var.db_name
    role_name     = var.db_user
  }

  # Configure default endpoint settings
  default_endpoint_settings {
    # autoscaling_limit_min_cu = 0.25
    autoscaling_limit_max_cu = 1.0
    # suspend_timeout_seconds  = 300
  }
}

# --- Secret Manager --- #
# Secret Manager: n8n encryption key
resource "random_password" "n8n_encryption_key" {
  length  = 32
  special = false
}
resource "google_secret_manager_secret" "encryption_key_secret" {
  secret_id = "${var.cloud_run_service_name}-encryption-key"
  project   = var.gcp_project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "encryption_key_secret_version" {
  secret      = google_secret_manager_secret.encryption_key_secret.id
  secret_data = random_password.n8n_encryption_key.result
}

# --- IAM Service Account & Permissions --- #
resource "google_service_account" "n8n_sa" {
  account_id   = var.service_account_name
  display_name = "n8n Service Account for Cloud Run"
  project      = var.gcp_project_id
}

resource "google_secret_manager_secret_iam_member" "encryption_key_secret_accessor" {
  project   = google_secret_manager_secret.encryption_key_secret.project
  secret_id = google_secret_manager_secret.encryption_key_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# --- Cloud Run Service --- #
locals {
  # Construct the image name dynamically
  n8n_image_name = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_repo_name}/${var.cloud_run_service_name}:latest"
  # Construct the service URL dynamically for env vars
  service_url  = "https://${var.cloud_run_service_name}-${google_project_service.run.project}.run.app" # Assuming default URL format
  service_host = replace(local.service_url, "https://", "")
}

resource "google_cloud_run_v2_service" "n8n" {
  name     = var.cloud_run_service_name
  location = var.gcp_region
  project  = var.gcp_project_id

  ingress             = "INGRESS_TRAFFIC_ALL" # Allow unauthenticated
  deletion_protection = false                 # Ensure this is false

  template {
    service_account = google_service_account.n8n_sa.email
    scaling {
      max_instance_count = var.cloud_run_max_instances # Guide uses 1
      min_instance_count = 0
    }
    
    containers {
      image = local.n8n_image_name # IMPORTANT: Build and push this image manually first
      
      ports {
        container_port = var.cloud_run_container_port
      }
      resources {
        limits = {
          cpu    = var.cloud_run_cpu
          memory = var.cloud_run_memory
        }
        startup_cpu_boost = true
      }
      env {
        name  = "N8N_PATH"
        value = "/"
      }
      
      env {
        name  = "N8N_PORT"
        value = "443"
      }
      env {
        name  = "N8N_PROTOCOL"
        value = "https"
      }
      env {
        name  = "DB_TYPE"
        value = "postgresdb"
      }
      env {
        name  = "DB_POSTGRESDB_DATABASE"
        value = var.db_name
      }
      env {
        name  = "DB_POSTGRESDB_USER"
        value = var.db_user
      }
      env {
        # Use Neon host from connection string
        name  = "DB_POSTGRESDB_HOST"
        value = split("@", split("//", split("?", neon_project.n8n_db.connection_uri)[0])[1])[1]
      }
      env {
        name  = "DB_POSTGRESDB_PORT"
        value = "5432"
      }
      env {
        name  = "DB_POSTGRESDB_PASSWORD"
        # Extract password from connection URI
        value = split(":", split("//", neon_project.n8n_db.connection_uri)[1])[1]
      }
      env {
        name  = "DB_POSTGRESDB_SCHEMA"
        value = "public"
      }
      env {
        name  = "N8N_USER_FOLDER"
        value = "/home/node/.n8n"
      }
      env {
        name  = "GENERIC_TIMEZONE"
        value = var.generic_timezone
      }
      env {
        name  = "QUEUE_HEALTH_CHECK_ACTIVE"
        value = "true"
      }
      env {
        name = "N8N_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.encryption_key_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "N8N_HOST"
        # Construct hostname dynamically using project number and region
        value = "${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "N8N_WEBHOOK_URL" # Deprecated but may be needed by older nodes/workflows
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "N8N_EDITOR_BASE_URL"
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "WEBHOOK_URL" # Current version
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "N8N_RUNNERS_ENABLED"
        value = "true"
      }
      env {
        name  = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS"
        value = "true"
      }
      env {
        name  = "N8N_DIAGNOSTICS_ENABLED"
        value = "false"
      }
      env {
        name  = "DB_POSTGRESDB_CONNECTION_TIMEOUT"
        value = "60000"
      }
      env {
        name  = "DB_POSTGRESDB_ACQUIRE_TIMEOUT"
        value = "60000"
      }
      env {
        name  = "EXECUTIONS_MODE" # Added from GitHub issue solution
        value = "regular"
      }
      env {
        name  = "N8N_LOG_LEVEL" # Added from GitHub issue solution
        value = "debug"
      }
      env {
        # https://docs.n8n.io/hosting/configuration/environment-variables/endpoints/
        # The interval (in seconds) at which the insights data should be flushed to the database.
        # Defaults to 30 seconds, which triggers the runtime 
        name  = "N8N_INSIGHTS_FLUSH_INTERVAL_SECONDS"
        value = "1800"
      }
      env {
        # https://docs.n8n.io/hosting/configuration/environment-variables/endpoints/
        # Enable the /metrics endpoint
        name  = "N8N_METRICS"
        value = "true"
      }
      env {
        # https://docs.n8n.io/hosting/configuration/environment-variables/logs/#n8n-logs
        # Output logs without ANSI colors
        name  = "NO_COLOR"
        value = "true"
      }

      startup_probe {
        initial_delay_seconds = 15 # Added from GitHub issue solution
        timeout_seconds       = 1
        period_seconds        = 1  # Reduced period for faster checks
        failure_threshold     = 45 # Fail after 1 minute (15s + 45s)
        http_get {
          path = "/healthz/readiness"
          port = var.cloud_run_container_port
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.run,
    google_secret_manager_secret_iam_member.encryption_key_secret_accessor,
    google_artifact_registry_repository.n8n_repo,
    neon_project.n8n_db
  ]
}

# Grant public access to the Cloud Run service
resource "google_cloud_run_v2_service_iam_member" "n8n_public_invoker" {
  project  = google_cloud_run_v2_service.n8n.project
  location = google_cloud_run_v2_service.n8n.location
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
