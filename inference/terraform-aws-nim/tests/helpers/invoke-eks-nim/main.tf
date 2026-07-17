terraform {
  required_version = ">= 1.14"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name."
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace the NIM is deployed into."
}

variable "release_name" {
  type        = string
  description = "Helm release name (used as label selector app.kubernetes.io/instance)."
}

variable "model_id" {
  type        = string
  description = "Model ID to send in the request body."
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region the cluster is in."
}

resource "terraform_data" "invoke" {
  provisioner "local-exec" {
    environment = {
      CLUSTER_NAME = var.cluster_name
      NAMESPACE    = var.namespace
      RELEASE_NAME = var.release_name
      MODEL_ID     = var.model_id
      REGION       = var.region
    }
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
      LB=$(kubectl get svc -n "$NAMESPACE" \
        -l "app.kubernetes.io/instance=$RELEASE_NAME" \
        -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
      curl -sf "http://$LB:8000/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with one word: hello\"}],\"max_tokens\":16}" \
        | jq -e '.choices[0].message.content | length > 0'
    EOT
  }
}
