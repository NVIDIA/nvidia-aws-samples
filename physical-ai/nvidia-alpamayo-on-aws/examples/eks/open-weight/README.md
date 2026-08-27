# Alpamayo 2 Super (open weights) on EKS

Deploys the open-weight **NVIDIA Alpamayo 2 Super** model — [`nvidia/Alpamayo2-Super`](https://huggingface.co/nvidia/Alpamayo2-Super), a 34B Vision-Language-Action model — to an **EKS Auto Mode** cluster via the module's open-weight path. The weights are fetched from HuggingFace and served on the cluster.

| | |
| --- | --- |
| **Platform** | Amazon EKS (Auto Mode) |
| **Model** | `nvidia/Alpamayo2-Super` (34B, open weights, OpenMDW-1.1) |
| **Instance** | `g6e.12xlarge` (4× L40S, 192 GB) — 34B needs multi-GPU |
| **Deploy path** | `open_weight` (`model_id` + `model_source`), sharded tensor-parallel ×4 |

Shared setup (prerequisites, GPU/instance background) lives in the [top-level README](../../../README.md).

**Model access:** Alpamayo 2 Super is gated under the OpenMDW-1.1 license. Accept it at [huggingface.co/nvidia/Alpamayo2-Super](https://huggingface.co/nvidia/Alpamayo2-Super), then store a HuggingFace token that has accepted the terms in AWS Secrets Manager and set `hf_secret_name`.

---

## Usage

```bash
cd examples/eks/open-weight
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars → set hf_secret_name (your HuggingFace token secret)

terraform init
terraform plan     # optional
terraform apply
```

`terraform apply` provisions a VPC + EKS Auto Mode cluster + a multi-GPU (`g6e.12xlarge`) NodePool, fetches the weights from HuggingFace to S3, and serves the model behind an NLB restricted to your public IP.

Watch readiness: `kubectl get pods -n alpamayo2 -w`.

---

## Invoking the endpoint

Resolve the NLB hostname, then send requests in the model's documented input/output format (camera images + egomotion + text query → reasoning + trajectory):

```bash
aws eks update-kubeconfig --name alpamayo2-dev-alpamayo2 --region <YOUR_REGION>
LB=$(kubectl get svc -n alpamayo2 -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}')
echo "endpoint: http://$LB:8000"
```

For the exact request schema, see the model card at [`nvidia/Alpamayo2-Super`](https://huggingface.co/nvidia/Alpamayo2-Super) and the [`NVlabs/alpamayo-recipes`](https://github.com/NVlabs/alpamayo-recipes) repo.

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
