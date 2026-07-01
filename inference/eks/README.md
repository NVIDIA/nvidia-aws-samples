# Inference on Amazon EKS

Inference samples deploying NVIDIA GPU-accelerated model serving on [Amazon Elastic Kubernetes Service (EKS)](https://aws.amazon.com/eks/), self-managed deployment on Kubernetes.

- [`nemotron-3-nano-single-node-deployment/`](nemotron-3-nano-single-node-deployment/) — Deploy Nemotron 3 Nano on a single GPU node with vLLM.
- [`nemotron-3-super-multi-node-efa-deployment/`](nemotron-3-super-multi-node-efa-deployment/) — Deploy Nemotron 3 Super across multiple nodes with EFA, using LeaderWorkerSet + Ray.

Each subfolder contains its own self-contained README with setup and usage instructions.
