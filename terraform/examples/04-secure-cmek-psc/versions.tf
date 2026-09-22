terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0, < 9.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 8.0, < 9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# google_project_service_identity, used to materialise the AlloyDB service
# agent before granting it access to the KMS key, lives in the beta provider.
provider "google-beta" {
  project = var.project_id
  region  = var.region
}
