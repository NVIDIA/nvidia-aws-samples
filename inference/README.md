# Inference

Samples for serving and running inference with NVIDIA models on AWS, organized by AWS service. Each example folder contains its own README with setup and usage instructions.

## Amazon Bedrock

Fully managed serverless inference on [Amazon Bedrock](https://aws.amazon.com/bedrock/).

- [`bedrock/nemotron-3-getting-started/`](bedrock/nemotron-3-getting-started/) — Getting started with NVIDIA Nemotron 3 on Bedrock: inference, tool calling, streaming, and reasoning modes.
- [`bedrock/nemotron-3-bedrock-knowledge-bases-rag/`](bedrock/nemotron-3-bedrock-knowledge-bases-rag/) — End-to-end RAG with Nemotron 3 using Bedrock Knowledge Bases and Guardrails.

## Amazon SageMaker

Inference on [Amazon SageMaker](https://aws.amazon.com/sagemaker/).

- [`sagemaker/nim/`](sagemaker/nim/) — Deploy NVIDIA NIM on SageMaker, via AWS Marketplace or self-hosted containers, with example notebooks across a range of models.

## Amazon EKS

Self-managed GPU-accelerated model serving on [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/).

- [`eks/nim/`](eks/nim/) — Deploy NVIDIA NIM on EKS using the NIM Operator, with a CDK-provisioned cluster and EFS/EBS storage options.
- [`eks/nemotron-3-nano-single-node-deployment/`](eks/nemotron-3-nano-single-node-deployment/) — Deploy Nemotron 3 Nano on a single GPU node with vLLM.
- [`eks/nemotron-3-super-multi-node-efa-deployment/`](eks/nemotron-3-super-multi-node-efa-deployment/) — Deploy Nemotron 3 Super across multiple nodes with EFA, using LeaderWorkerSet + Ray.
