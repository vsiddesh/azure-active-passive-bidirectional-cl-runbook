terraform {
  required_providers {
    confluent = {
      source = "confluentinc/confluent"
      #   version = "1.76.0"
    }
  }
}

provider "confluent" {
  cloud_api_key    = var.cc_cloud_api_key
  cloud_api_secret = var.cc_cloud_api_secret
}

provider "azurerm" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  features {}
}


variable "cc_cloud_api_key" {}
variable "cc_cloud_api_secret" {}
variable "cc_env_primary" {}
variable "cc_env_secondary" {}
variable "cc_service_account" {}
variable "client_id" {}
variable "client_secret" {}
variable "azure_region" {}
variable "subscription_id" {}
variable "tenant_id" {}
variable "prefix" {
  default = "proxy"
}
variable "admin_username" {}
variable "admin_password" {}

# Boolean Flag to use previously created clusters
variable "cc_use_existing_clusters" {
  type    = bool
  default = true
}
variable "cc_primary_cluster_id" {}
variable "cc_secondary_cluster_id" {}

variable "cc_failover_primary" {
  type    = bool
  default = false
}

 