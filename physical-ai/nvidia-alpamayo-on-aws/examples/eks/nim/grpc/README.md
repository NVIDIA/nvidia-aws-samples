# Alpamayo 1.5 on EKS — gRPC

Deploys the NVIDIA Alpamayo 1.5 NIM to an **EKS Auto Mode** cluster, serving its gRPC inference API on port **50051**. gRPC is EKS-only — SageMaker's invocation API is HTTP/1.1 and does not support gRPC.

| | |
| --- | --- |
| **Platform** | Amazon EKS (Auto Mode) |
| **Protocol** | gRPC (port 50051) |
| **Instance** | `g6e.xlarge` (1× L40S, 48 GB) |
| **Deploy path** | `nim_type = "custom"`, `protocol = "grpc"` → Deployment + Service via kubectl |

Alpamayo is a single container that serves both HTTP (8000) and gRPC (50051). This example reaches it over gRPC. Unlike `eks/http` (which uses the `nim-wfm` Helm chart and its persistent model cache), the gRPC path deploys the container directly, so cold starts re-download the model on each pod restart — prefer `eks/http` when you want the cached, production path.

Shared setup (prerequisites, NGC key, GPU/precision background) lives in the [top-level README](../../../../README.md).

---

## Usage

```bash
cd eks/grpc
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set ngc_secret_name (Path A) OR ngc_api_key (Path B)

terraform init
terraform plan     # optional
terraform apply
```

`terraform apply` provisions the same VPC + EKS Auto Mode cluster as `eks/http`, then deploys Alpamayo as a `Deployment` + gRPC `Service` behind an NLB restricted to your public IP.

Watch readiness: `kubectl get pods -n alpamayo -w`.

---

## Invoking the endpoint

gRPC needs a client that speaks Alpamayo's protobuf service (see the NGC quickstart's gRPC client). Point it at the NLB on port 50051:

```bash
aws eks update-kubeconfig --name alpamayo-dev-alpamayo --region <YOUR_REGION>
kubectl get pods -n alpamayo -w      # wait for 1/1 Ready

LB=$(kubectl get svc -n alpamayo -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}')

# Run the Alpamayo gRPC client against "$LB:50051"
grpcurl -plaintext "$LB:50051" list        # if the server exposes reflection
```

Port `50051` is set explicitly in `main.tf` (the module's gRPC default is 8001).

---

## Autoscaling

KEDA scales the deployment 1→3 replicas on `DCGM_FI_DEV_GPU_UTIL` (requires `enable_autoscaling = true` on the cluster — set in this example).

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
| `eks_release_names` | Deployment key → deployment name |
| `eks_namespaces` | Deployment key → Kubernetes namespace |
| `model_profile_cache_uris` | S3 URIs for pre-cached NIM manifest profiles |
