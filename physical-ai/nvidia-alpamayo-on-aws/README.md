# NVIDIA Alpamayo on AWS

Reference Terraform for deploying NVIDIA Alpamayo autonomous-driving models on AWS across **EKS** and **Amazon SageMaker**, built on the [`terraform-aws-nim`](../terraform-aws-nim) module. Two models are covered:

- **Alpamayo 1.5** — a 10B vision-language model, deployed from the packaged **NIM** ([`nvcr.io/nim/nvidia/alpamayo-1-5-10b`](https://catalog.ngc.nvidia.com/orgs/nim/nvidia/containers/alpamayo-1-5-10b)).
- **Alpamayo 2 Super** — a 34B Vision-Language-Action model, deployed from **open weights** ([`nvidia/Alpamayo2-Super`](https://huggingface.co/nvidia/Alpamayo2-Super)).

---

## Contents

1. [The models](#the-models)
2. [Examples](#examples)
3. [Access (NGC + HuggingFace)](#access-ngc--huggingface)
4. [GPU and instance selection](#gpu-and-instance-selection)
5. [Prerequisites](#prerequisites)
6. [Store your credentials](#store-your-credentials)
7. [Testing the endpoint](#testing-the-endpoint)
8. [Teardown](#teardown)
9. [References](#references)

---

## The models

**Alpamayo 1.5 (NIM).** A 10B vision-language model on the Cosmos-Reason2 backbone, RL post-trained for autonomous driving. Given multi-camera images + vehicle egomotion + a navigation prompt, it returns a driving trajectory. A single container exposes, at once:

| Protocol | Port | Path | Purpose |
| --- | --- | --- | --- |
| HTTP | 8000 | `POST /v1/infer` | Trajectory generation. Health: `GET /v1/health/ready` |
| HTTP | 8000 | `POST /v1/chat/completions` | OpenAI-compatible question answering |
| gRPC | 50051 | — | Trajectory generation (EKS only — SageMaker's invocation API is HTTP/1.1) |

**Alpamayo 2 Super (open weights).** A 34B Vision-Language-Action model (32B VLM backbone + 2.3B diffusion action decoder). Takes multi-camera images + egomotion + text and returns reasoning plus a 64-waypoint trajectory. Distributed as open weights under the OpenMDW-1.1 license.

---

## Examples

Each is a self-contained, independently-runnable Terraform root under `examples/`. `cd` into one and follow its README. `examples/eks/nim/http` is the recommended starting point.

| Example | Path | Model | Platform |
| --- | --- | --- | --- |
| **NIM on EKS (HTTP)** | [`examples/eks/nim/http/`](examples/eks/nim/http/) | Alpamayo 1.5 (NIM, `/v1/infer` 8000) | EKS Auto Mode |
| **NIM on EKS (gRPC)** | [`examples/eks/nim/grpc/`](examples/eks/nim/grpc/) | Alpamayo 1.5 (NIM, gRPC 50051) | EKS Auto Mode |
| **NIM on SageMaker** | [`examples/sagemaker/nim/`](examples/sagemaker/nim/) | Alpamayo 1.5 (NIM, shim) | SageMaker real-time |
| **Open-weight on EKS** | [`examples/eks/open-weight/`](examples/eks/open-weight/) | Alpamayo 2 Super (HF weights) | EKS Auto Mode |
| **Open-weight on SageMaker** | [`examples/sagemaker/open-weight/`](examples/sagemaker/open-weight/) | Alpamayo 2 Super (HF weights) | SageMaker real-time |

The two `eks/nim` examples reach the same container over different protocols (HTTP on 8000, gRPC on 50051).

---

## Access (NGC + HuggingFace)

- **Alpamayo 1.5 NIM** is pulled from NGC (`nvcr.io/nim/nvidia/alpamayo-1-5-10b:1.0.0`). A standard NGC account with access to the NIM is sufficient — no special access-program entitlement. You need an NGC API key (`nvapi-…`).
- **Alpamayo 2 Super open weights** are gated under OpenMDW-1.1. Accept the license at [huggingface.co/nvidia/Alpamayo2-Super](https://huggingface.co/nvidia/Alpamayo2-Super) and use a HuggingFace token that has accepted the terms.

The NIM examples use the NGC key; the open-weight examples use the HuggingFace token.

---

## GPU and instance selection

| Model | Instance | GPUs | Why |
| --- | --- | --- | --- |
| Alpamayo 1.5 (10B NIM) | `g6e.xlarge` / `ml.g6e.xlarge` | 1× L40S (48 GB) | Right-sized single-GPU; supports all NIM precisions (`bf16`/`fp8`/`w4a16`) |
| Alpamayo 2 Super (34B) | `g6e.12xlarge` / `ml.g6e.12xlarge` | 4× L40S (192 GB) | 34B needs multi-GPU; sharded tensor-parallel ×4 |

On AWS, L40S (the `g6e` family) is the practical choice — H100/H200 (`p5`) only come in 8-GPU instances, and RTX 4090 isn't offered. The Alpamayo images are large, so first pull and initial cold start take longer than a typical model — budget extra time on the first apply.

For the NIM, precision is selected at startup via `NIM_PRECISION` (`bf16`/`fp8`/`w4a16`); leave it unset to auto-select per GPU.

---

## Prerequisites

| Tool | Version | Install (macOS) |
| --- | --- | --- |
| AWS CLI v2 | ≥ 2.15 | `brew install awscli` |
| Terraform | ≥ 1.14 | `brew install terraform` (or `tfenv`) |
| kubectl | ≥ 1.31 | `brew install kubectl` (EKS examples) |
| jq | latest | `brew install jq` |

Plus an AWS account with programmatic access, service quota for `g6e` instances in your region, and the relevant credential (NGC key for NIM, HuggingFace token for open-weight).

---

## Store your credentials

Both are stored in AWS Secrets Manager and referenced by name in each example's `terraform.tfvars`.

**NGC key (NIM examples):**
```bash
aws secretsmanager create-secret \
  --name alpamayo-ngc-api-key \
  --secret-string '{"access-key":"<PASTE_YOUR_NGC_API_KEY>"}' \
  --region <YOUR_REGION>
# → ngc_secret_name = "alpamayo-ngc-api-key"
```

**HuggingFace token (open-weight examples):**
```bash
aws secretsmanager create-secret \
  --name alpamayo-hf-token \
  --secret-string "<PASTE_YOUR_HF_TOKEN>" \
  --region <YOUR_REGION>
# → hf_secret_name = "alpamayo-hf-token"
```

---

## Testing the endpoint

For the **NIM** (Alpamayo 1.5), the HTTP trajectory endpoint is `POST /v1/infer`; the NIM ships a sample and a payload builder (see the [NGC quickstart](https://catalog.ngc.nvidia.com/orgs/nim/nvidia/containers/alpamayo-1-5-10b)):

```bash
python3 build_http_payload.py --endpoint infer --sample-dir sample_data > alpamayo-infer.json
curl -X POST http://<ENDPOINT>:8000/v1/infer --data-binary @alpamayo-infer.json
```

For **open weights** (Alpamayo 2 Super), the request schema (camera images + egomotion + text → reasoning + trajectory) is documented on the [model card](https://huggingface.co/nvidia/Alpamayo2-Super) and in [`NVlabs/alpamayo-recipes`](https://github.com/NVlabs/alpamayo-recipes).

Each example README shows how to resolve its own endpoint address.

---

## Teardown

From inside whichever example you deployed:

```bash
terraform destroy
```

The module's cleanup hooks drain the NLB / delete the endpoint and clean orphaned ENIs before tearing down the VPC. Re-run if it fails partway — the hooks are idempotent.

---

## References

- [Alpamayo 1.5 NIM on NGC](https://catalog.ngc.nvidia.com/orgs/nim/nvidia/containers/alpamayo-1-5-10b)
- [Alpamayo 2 Super on HuggingFace](https://huggingface.co/nvidia/Alpamayo2-Super)
- [NVlabs/alpamayo-recipes](https://github.com/NVlabs/alpamayo-recipes) — fine-tuning, RL post-training, quantization recipes
- [`terraform-aws-nim` module](../terraform-aws-nim) — the module these examples consume
- [nvidia-svd-on-aws](../eks/nvidia-svd-on-aws) — sibling gRPC media-NIM sample (EKS-only)
