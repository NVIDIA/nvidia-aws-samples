# Alpamayo 1.5 on SageMaker — HTTP

Deploys the NVIDIA Alpamayo 1.5 NIM as a managed **Amazon SageMaker** real-time endpoint. SageMaker's invocation contract is HTTP-only (`POST /invocations` + `GET /ping`), so the module wraps the container with its Caddy shim.

| | |
| --- | --- |
| **Platform** | Amazon SageMaker (real-time endpoint) |
| **Protocol** | HTTP via the Caddy shim |
| **Instance** | `ml.g6e.xlarge` (1× L40S, 48 GB) |
| **Deploy path** | `sagemaker_endpoints` — no VPC required (managed) |

The shim maps SageMaker's fixed paths onto Alpamayo's:

- `GET /ping` → `GET /v1/health/ready` (shim default)
- `POST /invocations` → `POST /v1/infer` — Alpamayo's trajectory endpoint, set via `shim_config = { infer_path = "/v1/infer" }`. (The shim's default target is `/v1/chat/completions`, which Alpamayo also serves for its Q&A endpoint.)

Shared setup (prerequisites, NGC key, GPU/precision background, payload format) lives in the [top-level README](../../../README.md).

---

## Usage

```bash
cd sagemaker/http
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set ngc_secret_name (Path A) OR ngc_api_key (Path B)

terraform init
terraform plan     # optional
terraform apply
```

`terraform apply` builds the shim image, registers the model with SageMaker, and creates a real-time endpoint. No VPC is created — SageMaker manages the network. The Alpamayo image is large, so the first build and endpoint cold start take longer than a typical NIM.

---

## Invoking the endpoint

```bash
python3 build_http_payload.py --endpoint infer --sample-dir sample_data > alpamayo-infer.json

aws sagemaker-runtime invoke-endpoint \
  --endpoint-name alpamayo-dev-alpamayo \
  --content-type application/json \
  --body fileb://alpamayo-infer.json \
  --region <YOUR_REGION> \
  /dev/stdout
```

Endpoint name (`alpamayo-dev-alpamayo`) is the default; use `terraform output endpoint_names` for the actual value.

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
