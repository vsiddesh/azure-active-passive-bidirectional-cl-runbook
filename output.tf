output "primary_cluster" {
  sensitive = false
  value = {
    region             = var.azure_region
    bootstrap_endpoint = data.confluent_kafka_cluster.primary.bootstrap_endpoint
    cluster_id         = data.confluent_kafka_cluster.primary.id
    cluster_api_key    = confluent_api_key.cluster-api-key-primary.id
    cluster_api_secret = nonsensitive(confluent_api_key.cluster-api-key-primary.secret)
    topic              = confluent_kafka_topic.primary.topic_name
    # mirror_topic       = data.confluent_kafka_mirror_topic.primary.id
  }
}

output "secondary_cluster" {
  sensitive = false
  value = {
    region             = var.azure_region
    bootstrap_endpoint = data.confluent_kafka_cluster.secondary.bootstrap_endpoint
    cluster_id         = data.confluent_kafka_cluster.secondary.id
    cluster_api_key    = confluent_api_key.cluster-api-key-secondary.id
    cluster_api_secret = nonsensitive(confluent_api_key.cluster-api-key-secondary.secret)
  }
}

output "proxy_public_ip" {
  sensitive = false
  value     = azurerm_public_ip.pubicip.ip_address
}
