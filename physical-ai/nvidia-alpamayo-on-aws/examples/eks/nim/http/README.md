# Alpamayo 1.5 on EKS — HTTP

Deploys the NVIDIA Alpamayo 1.5 NIM to an **EKS Auto Mode** cluster, serving its HTTP trajectory API (`POST /v1/infer` on port 8000) via the `nim-wfm` Helm chart. Recommended starting point.

| | |
| --- | --- |
| **Platform** | Amazon EKS (Auto Mode) |
| **Protocol** | HTTP — `POST /v1/infer` (8000), health `GET /v1/health/ready` |
| **Instance** | `g6e.xlarge` (1× L40S, 48 GB) |
| **Deploy path** | `nim_type = "custom"` + the `nim-wfm` NGC Helm chart (`1.1.1`) |

Shared setup (prerequisites, NGC key, GPU/precision background, payload format) lives in the [top-level README](../../../../README.md). This page covers what's specific to this example.

> The Alpamayo NIM also serves **gRPC on port 50051**. This example publishes the HTTP port (8000) on the NLB; to reach gRPC, publish 50051 on the Service/NLB as well. See the NGC quickstart for the gRPC client.

---

## Usage

```bash
cd eks/http
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set ngc_secret_name (Path A) OR ngc_api_key (Path B)

terraform init
terraform plan     # optional
terraform apply
```

`terraform apply` provisions a VPC (4 AZs, single NAT) + EKS Auto Mode cluster + GPU NodePool + ECR mirror + NGC pull secret + the Alpamayo Helm release + an HTTP `Service` fronted by an NLB, restricted to your public IP.

### Apply timeline

| Phase | Approx. time |
| --- | --- |
| VPC + EKS Auto Mode cluster | 15–20 min |
| Image sync to ECR + KEDA/monitoring addons | concurrent |
| Helm deploy + NIM cold start (model download) | 15–20 min (large image) |

The NIM stays `0/1 Running` until the model finishes loading. Watch with `kubectl get pods -n alpamayo -w`.

---

## Invoking the endpoint

```bash
aws eks update-kubeconfig --name alpamayo-dev-alpamayo --region <YOUR_REGION>
kubectl get pods -n alpamayo -w      # wait for 1/1 Ready

# Grab the NLB hostname
LB=$(kubectl get svc -n alpamayo -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}')

# Health, then trajectory inference (payload build documented in the top-level README)
curl "http://$LB:8000/v1/health/ready"
python3 build_http_payload.py --endpoint infer --sample-dir sample_data > alpamayo-infer.json
curl -X POST "http://$LB:8000/v1/infer" --data-binary @alpamayo-infer.json
```

Cluster/namespace names above (`alpamayo-dev-alpamayo`, `alpamayo`) are the defaults from this example. If you change `project_prefix`/`environment` in `main.tf`, use `terraform output`.

---

## Autoscaling

KEDA scales the deployment 1→3 replicas on `DCGM_FI_DEV_GPU_UTIL` (requires `enable_autoscaling = true` on the cluster — set in this example). Each new replica requests its own GPU, so Karpenter provisions an additional `g6e.xlarge` node under sustained load.

---

## Teardown

```bash
terraform destroy
```

---

## Outputs

| Output | Description |
| --- | --- |
| `eks_cluster_names` | Cluster key → EKS cluster name |
| `eks_release_names` | Deployment key → Helm release name |
| `eks_namespaces` | Deployment key → Kubernetes namespace |
| `model_profile_cache_uris` | S3 URIs for pre-cached NIM manifest profiles |
