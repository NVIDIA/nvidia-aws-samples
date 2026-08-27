variable "region" {
  type        = string
  description = "AWS region to deploy into. Defaults to the current AWS provider region if not set. Alpamayo 2 Super (34B) needs multi-GPU g6e.12xlarge; g6e capacity is best in us-east-1, us-east-2, us-west-2."
  default     = null
}

variable "hf_secret_name" {
  type        = string
  default     = null
  description = "Name of the AWS Secrets Manager secret holding your HuggingFace token. Alpamayo 2 Super is gated under the OpenMDW-1.1 license — accept it at huggingface.co/nvidia/Alpamayo2-Super, then store a token that has accepted the terms. Required to download the weights."
}
