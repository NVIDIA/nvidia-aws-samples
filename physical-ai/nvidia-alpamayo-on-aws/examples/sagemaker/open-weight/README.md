# Alpamayo 2 Super (open weights) on SageMaker

Deploys the open-weight **NVIDIA Alpamayo 2 Super** model — [`nvidia/Alpamayo2-Super`](https://huggingface.co/nvidia/Alpamayo2-Super), a 34B Vision-Language-Action model — as a managed **Amazon SageMaker** real-time endpoint via the module's open-weight path. The weights are fetched from HuggingFace to S3 and served behind the endpoint.

| | |
| --- | --- |
| **Platform** | Amazon SageMaker (real-time endpoint) |
| **Model** | `nvidia/Alpamayo2-Super` (34B, open weights, OpenMDW-1.1) |
| **Instance** | `ml.g6e.12xlarge` (4× L40S, 192 GB) — 34B needs multi-GPU |
| **Deploy path** | `open_weight` (`model_id` + `model_source`), sharded tensor-parallel ×4 |

Shared setup (prerequisites, GPU/instance background) lives in the [top-level README](../../../README.md).

**Model access:** Alpamayo 2 Super is gated under the OpenMDW-1.1 license. Accept it at [huggingface.co/nvidia/Alpamayo2-Super](https://huggingface.co/nvidia/Alpamayo2-Super), then store a HuggingFace token that has accepted the terms in AWS Secrets Manager and set `hf_secret_name`.

---

## Usage

```bash
cd examples/sagemaker/open-weight
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set hf_secret_name (your HuggingFace token secret)

terraform init
terraform plan     # optional
terraform apply
```

`terraform apply` fetches the weights from HuggingFace to S3, builds the serving image, and creates a multi-GPU (`ml.g6e.12xlarge`) SageMaker real-time endpoint. No VPC is created — SageMaker manages the network.

---

## Invoking the endpoint

Invoke the endpoint in the model's documented input/output format (camera images + egomotion + text query → reasoning + trajectory):

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name alpamayo2-dev-alpamayo2 \
  --content-type application/json \
  --body fileb://request.json \
  --region <YOUR_REGION> \
  /dev/stdout
```

For the exact request schema, see the model card at [`nvidia/Alpamayo2-Super`](https://huggingface.co/nvidia/Alpamayo2-Super) and the [`NVlabs/alpamayo-recipes`](https://github.com/NVlabs/alpamayo-recipes) repo. Endpoint name (`alpamayo2-dev-alpamayo2`) is the default; use `terraform output endpoint_names` for the actual value.

---

## Teardown

```bash
terraform destroy
```

---

## Outputs

| Output | Description |
| --- | --- |
| `endpoint_names` | Endpoint key → SageMaker endpoint name |
| `sagemaker_endpoint_arns` | Endpoint key → SageMaker endpoint ARN |
| `async_output_prefixes` | Endpoint key → S3 output prefix (async endpoints only) |
