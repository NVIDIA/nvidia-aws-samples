# Physical AI

Samples for deploying NVIDIA **Physical AI** models on AWS — world foundation
models, robotics, and simulation workloads. Each sample is self-contained with its
own README for setup and usage.

Physical AI models are served as NVIDIA NIMs; these samples build on the
[`inference/terraform-aws-nim/`](../inference/terraform-aws-nim/) module for the
underlying AWS infrastructure (EKS Auto Mode, SageMaker, networking, image sync).

## Samples

- [`nvidia-cosmos-on-aws/`](nvidia-cosmos-on-aws/) — Deploy the **NVIDIA Cosmos 3
  Generator** world foundation model (text or image → generated video) on AWS,
  with **EKS** (raw manifest, synchronous HTTP `POST /v1/infer`) and **SageMaker async**
  (Caddy shim, S3-backed) variants. Cosmos 3 is a Mixture-of-Transformer world
  model; this sample deploys the Generator tower. Requires P5/P6
  (H100/H200/Blackwell) GPUs.

## Requirements

- An AWS account with quota for the GPU instances each sample requires (Cosmos 3
  needs P5/P6 — Hopper or newer; see the sample README for the full support matrix)
- Access to the relevant NVIDIA NIM container images on NGC
- The AWS CLI installed and configured

See each sample's README for its specific prerequisites, cost profile, and
invocation examples.
