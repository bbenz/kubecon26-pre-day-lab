terraform {
  required_version = ">= 1.9.0"
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.4, < 3.0"
    }
  }
}
