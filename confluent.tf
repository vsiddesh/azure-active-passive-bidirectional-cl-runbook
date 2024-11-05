data "confluent_environment" "default" {
  id = var.cc_env
}

data "confluent_service_account" "default" {
  id = var.cc_service_account
}

data "confluent_kafka_cluster" "primary" {
  id = local.primary_cluster_id
  environment {
    id = var.cc_env
  }
}

data "confluent_kafka_cluster" "secondary" {
  id = local.secondary_cluster_id
  environment {
    id = var.cc_env
  }
}


locals {
  primary_cluster_id   = var.cc_use_existing_clusters == true ? var.cc_primary_cluster_id : confluent_kafka_cluster.primary[0].id
  secondary_cluster_id = var.cc_use_existing_clusters == true ? var.cc_secondary_cluster_id : confluent_kafka_cluster.secondary[0].id
}


resource "confluent_kafka_cluster" "primary" {
  count        = var.cc_use_existing_clusters == true ? 0 : 1
  display_name = "active-passive-primary"
  availability = "SINGLE_ZONE"
  cloud        = "AZURE"
  region       = var.azure_region
  dedicated {
    cku = 2
  }
  environment {
    id = data.confluent_environment.default.id
  }

  lifecycle {
    prevent_destroy = false
  }
}


resource "confluent_kafka_cluster" "secondary" {
  count        = var.cc_use_existing_clusters == true ? 0 : 1
  display_name = "active-passive-secondary"
  availability = "SINGLE_ZONE"
  cloud        = "AZURE"
  region       = var.azure_region
  dedicated {
    cku = 2
  }

  environment {
    id = data.confluent_environment.default.id
  }

  lifecycle {
    prevent_destroy = false
  }
}

/*
  Create role bindings for the service accounts
  See https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/security-cloud.html#rbac-roles-and-ak-acls-summary 
*/

resource "confluent_role_binding" "primary" {
  for_each = toset(["CloudClusterAdmin", "Operator"])

  principal   = "User:${data.confluent_service_account.default.id}"
  role_name   = each.value
  crn_pattern = data.confluent_kafka_cluster.primary.rbac_crn
}
resource "confluent_role_binding" "topics_primary" {
  for_each = toset(["DeveloperRead", "ResourceOwner"])

  principal   = "User:${data.confluent_service_account.default.id}"
  role_name   = each.value
  crn_pattern = "${data.confluent_kafka_cluster.primary.rbac_crn}/kafka=${data.confluent_kafka_cluster.primary.id}/topic=*"
}

resource "confluent_role_binding" "secondary" {
  for_each = toset(["CloudClusterAdmin", "Operator"])

  principal   = "User:${data.confluent_service_account.default.id}"
  role_name   = each.value
  crn_pattern = data.confluent_kafka_cluster.secondary.rbac_crn
}

resource "confluent_role_binding" "topics_secondary" {
  for_each = toset(["DeveloperRead", "ResourceOwner"])

  principal   = "User:${data.confluent_service_account.default.id}"
  role_name   = each.value
  crn_pattern = "${data.confluent_kafka_cluster.secondary.rbac_crn}/kafka=${data.confluent_kafka_cluster.secondary.id}/topic=*"
}

resource "confluent_api_key" "cluster-api-key-primary" {
  display_name = "primary-active-passive-kafka-api-key"
  description  = "Kafka API Key to manage the primary cluster"
  owner {
    id          = data.confluent_service_account.default.id
    api_version = data.confluent_service_account.default.api_version
    kind        = data.confluent_service_account.default.kind
  }

  managed_resource {
    id          = data.confluent_kafka_cluster.primary.id
    api_version = data.confluent_kafka_cluster.primary.api_version
    kind        = data.confluent_kafka_cluster.primary.kind

    environment {
      id = data.confluent_environment.default.id
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_api_key" "cluster-api-key-secondary" {
  display_name = "secondary-active-passive-kafka--api-key"
  description  = "Kafka API Key to manage the secondary cluster"
  owner {
    id          = data.confluent_service_account.default.id
    api_version = data.confluent_service_account.default.api_version
    kind        = data.confluent_service_account.default.kind
  }

  managed_resource {
    id          = data.confluent_kafka_cluster.secondary.id
    api_version = data.confluent_kafka_cluster.secondary.api_version
    kind        = data.confluent_kafka_cluster.secondary.kind

    environment {
      id = data.confluent_environment.default.id
    }
  }

  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_kafka_topic" "primary" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.primary.id
  }
  topic_name    = "active-passive-a"
  rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-primary.id
    secret = confluent_api_key.cluster-api-key-primary.secret
  }

  lifecycle {
    prevent_destroy = false
  }
  depends_on = [
    confluent_role_binding.topics_primary,
    confluent_role_binding.topics_secondary,
  ]
}

resource "confluent_cluster_link" "default" {
  link_name = "active-passive-test"
  link_mode = "BIDIRECTIONAL"
  config = {
    "consumer.offset.sync.enable" = "true"
    "consumer.offset.sync.ms"     = 1000
    "topic.config.sync.ms"        = 1000
    "acl.sync.enable"             = "true"
  }
  local_kafka_cluster {
    id            = data.confluent_kafka_cluster.secondary.id
    rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
    credentials {
      key    = confluent_api_key.cluster-api-key-secondary.id
      secret = confluent_api_key.cluster-api-key-secondary.secret
    }
  }
  remote_kafka_cluster {
    id                 = data.confluent_kafka_cluster.primary.id
    bootstrap_endpoint = data.confluent_kafka_cluster.primary.bootstrap_endpoint
    credentials {
      key    = confluent_api_key.cluster-api-key-primary.id
      secret = confluent_api_key.cluster-api-key-primary.secret
    }
  }
  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_kafka_mirror_topic" "secondary" {
  source_kafka_topic {
    topic_name = confluent_kafka_topic.primary.topic_name
  }
  cluster_link {
    link_name = confluent_cluster_link.default.link_name
  }
  kafka_cluster {
    id            = data.confluent_kafka_cluster.secondary.id
    rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
    credentials {
      key    = confluent_api_key.cluster-api-key-secondary.id
      secret = confluent_api_key.cluster-api-key-secondary.secret
    }
  }
  lifecycle {
    prevent_destroy = false
  }
}

resource "confluent_cluster_link" "reverse" {
  link_name = "active-passive-test"
  link_mode = "BIDIRECTIONAL"
  config = {
    "consumer.offset.sync.enable" = "true"
    "consumer.offset.sync.ms"     = 1000
    "topic.config.sync.ms"        = 1000
  }
  local_kafka_cluster {
    id            = data.confluent_kafka_cluster.primary.id
    rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
    credentials {
      key    = confluent_api_key.cluster-api-key-primary.id
      secret = confluent_api_key.cluster-api-key-primary.secret
    }
  }
  remote_kafka_cluster {
    id                 = data.confluent_kafka_cluster.secondary.id
    bootstrap_endpoint = data.confluent_kafka_cluster.secondary.bootstrap_endpoint
    credentials {
      key    = confluent_api_key.cluster-api-key-secondary.id
      secret = confluent_api_key.cluster-api-key-secondary.secret
    }
  }
  lifecycle {
    prevent_destroy = false
  }
}

## Primary Clusters Acls

resource "confluent_kafka_acl" "describe-config-primary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.primary.id
  }
  resource_type = "TOPIC"
  resource_name = "active-passive-a"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "DESCRIBE_CONFIGS"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-primary.id
    secret = confluent_api_key.cluster-api-key-primary.secret
  }
}

resource "confluent_kafka_acl" "read-primary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.primary.id
  }
  resource_type = "TOPIC"
  resource_name = "active-passive-a"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-primary.id
    secret = confluent_api_key.cluster-api-key-primary.secret
  }
}

resource "confluent_kafka_acl" "describe-primary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.primary.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "DESCRIBE"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-primary.id
    secret = confluent_api_key.cluster-api-key-primary.secret
  }
}

resource "confluent_kafka_acl" "alter-primary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.primary.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "ALTER"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.primary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-primary.id
    secret = confluent_api_key.cluster-api-key-primary.secret
  }
}

## Secondary Cluster ACLs


resource "confluent_kafka_acl" "describe-config-secondary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.secondary.id
  }
  resource_type = "TOPIC"
  resource_name = "active-passive-a"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "DESCRIBE_CONFIGS"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-secondary.id
    secret = confluent_api_key.cluster-api-key-secondary.secret
  }
}

resource "confluent_kafka_acl" "read-secondary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.secondary.id
  }
  resource_type = "TOPIC"
  resource_name = "active-passive-a"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-secondary.id
    secret = confluent_api_key.cluster-api-key-secondary.secret
  }
}

resource "confluent_kafka_acl" "describe-secondary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.secondary.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "DESCRIBE"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-secondary.id
    secret = confluent_api_key.cluster-api-key-secondary.secret
  }
}

resource "confluent_kafka_acl" "alter-secondary-cluster" {
  kafka_cluster {
    id = data.confluent_kafka_cluster.secondary.id
  }
  resource_type = "CLUSTER"
  resource_name = "kafka-cluster"
  pattern_type  = "LITERAL"
  principal     = "User:${var.cc_service_account}"
  host          = "*"
  operation     = "ALTER"
  permission    = "ALLOW"
  rest_endpoint = data.confluent_kafka_cluster.secondary.rest_endpoint
  credentials {
    key    = confluent_api_key.cluster-api-key-secondary.id
    secret = confluent_api_key.cluster-api-key-secondary.secret
  }
}




