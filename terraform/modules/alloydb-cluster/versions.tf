terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # AlloyDB resources used here (including connection_pool_config for
      # Managed Connection Pooling) are GA in the 8.x provider.
      version = ">= 8.0, < 9.0"
    }
  }
}
