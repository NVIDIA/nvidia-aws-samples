terraform {
  required_version = ">= 1.14"
}

variable "endpoint_name" {
  type        = string
  description = "SageMaker endpoint name to invoke."
}

variable "model" {
  type        = string
  description = "Model name to send in the request body (e.g. meta/llama-3.1-8b-instruct)."
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region the endpoint is in."
}

resource "terraform_data" "invoke" {
  provisioner "local-exec" {
    environment = {
      ENDPOINT_NAME = var.endpoint_name
      MODEL         = var.model
      REGION        = var.region
    }
    command = <<-EOT
      set -e
      printf '{"model":"%s","messages":[{"role":"user","content":"Reply with one word: hello"}],"max_tokens":16}' \
        "$MODEL" > /tmp/nim-request.json
      aws sagemaker-runtime invoke-endpoint \
        --endpoint-name "$ENDPOINT_NAME" \
        --content-type application/json \
        --body fileb:///tmp/nim-request.json \
        --region "$REGION" \
        /tmp/nim-response.json
      echo "=== Response ===" && cat /tmp/nim-response.json && echo ""
      jq -e '.choices[0].message.content | length > 0' /tmp/nim-response.json
    EOT
  }
}
