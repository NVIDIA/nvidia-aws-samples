# ---------------------------------------------------------------------------
# Destroy-time cleanup: orphan ENIs and LBC-created resources
#
# Two distinct sources of orphan VPC interfaces can block destroy with
# "DependencyViolation: resource has a dependent object":
#
# 1. LBC-managed SGs (tag kubernetes.io/cluster/<name>=owned)
#    The AWS Load Balancer Controller creates these for NLB Services. The LBC
#    deletes them async after `helm uninstall` removes the Service — but the
#    deletion may not finish before Terraform reaches VPC destruction.
#
# 2. CodeBuild ENIs orphaned in the Terraform-managed cluster SG
#    The cluster SG is shared between Auto Mode nodes and the deploy-nim
#    CodeBuild project (CodeBuild VPC mode attaches ENIs to it). CodeBuild
#    normally releases its ENIs when a build reaches a terminal state, but if
#    Terraform deletes the CodeBuild project while a build is IN_PROGRESS
#    (e.g. destroy fired during a node-pending poll loop), the abort path
#    leaves ENIs in `status=available` stuck on the cluster SG. The LBC-tag
#    filter above does NOT catch these because the cluster SG is OUR resource,
#    not LBC-tagged (and tagging it as Kubernetes-owned would invite LBC to
#    mutate a Terraform-managed resource — wrong tradeoff).
#
# This resource runs on destroy and handles both. Runs before the cluster is
# deleted (cleanup depends_on the cluster → destroy order reverses it).
#
# on_failure = continue: if resources are already gone, proceed cleanly. If
# they aren't, Terraform's subsequent SG delete will surface the real error.
# ---------------------------------------------------------------------------

resource "terraform_data" "cleanup_lbc_resources" {
  input = {
    cluster_name  = var.name_prefix
    region        = var.region
    cluster_sg_id = aws_security_group.cluster.id
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      echo "Cleaning up LBC-managed SGs and ENIs for cluster ${self.input.cluster_name}..."

      for i in $(seq 1 20); do
        SG_IDS=$(aws ec2 describe-security-groups \
          --region "${self.input.region}" \
          --filters "Name=tag:kubernetes.io/cluster/${self.input.cluster_name},Values=owned" \
          --query 'SecurityGroups[].GroupId' \
          --output text 2>/dev/null || true)

        if [ -z "$(echo $SG_IDS | tr -d '[:space:]')" ]; then
          echo "No LBC-managed security groups found — cleanup complete."
          break
        fi

        echo "Attempt $i/20 — found: $SG_IDS"

        for SG_ID in $SG_IDS; do
          # Delete dependent ENIs first
          ENI_IDS=$(aws ec2 describe-network-interfaces \
            --region "${self.input.region}" \
            --filters "Name=group-id,Values=$SG_ID" \
            --query 'NetworkInterfaces[].NetworkInterfaceId' \
            --output text 2>/dev/null || true)
          for ENI_ID in $ENI_IDS; do
            echo "  Deleting ENI $ENI_ID"
            aws ec2 delete-network-interface \
              --region "${self.input.region}" \
              --network-interface-id "$ENI_ID" 2>/dev/null || true
          done

          # Revoke all ingress rules before deleting the SG
          INGRESS=$(aws ec2 describe-security-groups \
            --region "${self.input.region}" \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null || echo "[]")
          if [ "$INGRESS" != "[]" ] && [ "$INGRESS" != "null" ]; then
            aws ec2 revoke-security-group-ingress \
              --region "${self.input.region}" \
              --group-id "$SG_ID" \
              --ip-permissions "$INGRESS" 2>/dev/null || true
          fi

          echo "  Deleting SG $SG_ID"
          aws ec2 delete-security-group \
            --region "${self.input.region}" \
            --group-id "$SG_ID" 2>/dev/null || true
        done

        sleep 15
      done

      # ---------------------------------------------------------------------
      # Drain orphan ENIs from the Terraform-managed cluster SG.
      # Only target status=available (unattached). Attached ENIs indicate
      # something is still using the SG — Terraform's destroy should surface
      # that as a real error, not be papered over here.
      # ---------------------------------------------------------------------
      echo "Draining orphan ENIs from cluster SG ${self.input.cluster_sg_id}..."

      for i in $(seq 1 12); do
        ENI_IDS=$(aws ec2 describe-network-interfaces \
          --region "${self.input.region}" \
          --filters "Name=group-id,Values=${self.input.cluster_sg_id}" "Name=status,Values=available" \
          --query 'NetworkInterfaces[].NetworkInterfaceId' \
          --output text 2>/dev/null || true)

        if [ -z "$(echo $ENI_IDS | tr -d '[:space:]')" ]; then
          echo "  No orphan ENIs on cluster SG — done."
          break
        fi

        echo "  Attempt $i/12 — orphan ENIs: $ENI_IDS"
        for ENI_ID in $ENI_IDS; do
          echo "    Deleting orphan ENI $ENI_ID"
          aws ec2 delete-network-interface \
            --region "${self.input.region}" \
            --network-interface-id "$ENI_ID" 2>/dev/null || true
        done

        sleep 10
      done

      exit 0
    EOT
  }

  # No depends_on here — the cluster depends on this resource (see main.tf).
  # On destroy that reverses: cluster is deleted FIRST, then this cleanup runs.
  # We use var.name_prefix (= the cluster name) to avoid a circular reference.
}

# ---------------------------------------------------------------------------
# Destroy-time fence: EKS cluster destroyed before consumer IGW
#
# Holds the IGW ID (or null) in Terraform state. The EKS cluster depends_on
# this resource (see main.tf), so at destroy time the cluster and LBC cleanup
# above always complete before this resource is released. input = null when
# internet_gateway_id is not set — harmless, the fence still provides ordering.
# Consumers that create their aws_internet_gateway in the same workspace should
# add depends_on = [module.<nim>] to their IGW to enforce full teardown order.
# Always created unconditionally — count on a resource attribute causes
# "Invalid count argument" at plan time when the value is not yet known.
# ---------------------------------------------------------------------------

resource "terraform_data" "internet_gateway_destroy_fence" {
  input = var.internet_gateway_id
}

# ---------------------------------------------------------------------------
# Destroy-time cleanup: autoscaling stack (KEDA + Prometheus + DCGM)
#
# When enable_autoscaling = true, cluster-setup installs KEDA, kube-prometheus-
# stack, and DCGM exporter as Helm releases. On destroy, we run helm uninstall
# BEFORE the cluster is torn down so the operator-managed resources (Prometheus
# StatefulSet PVCs, KEDA ScaledObject cleanups, DaemonSet pod termination) drain
# cleanly. Order matters — this resource depends_on the cluster, so at destroy
# the dependency reverses: this cleanup runs FIRST, then the cluster is deleted.
#
# on_failure = continue: if any release is already gone or the cluster API is
# unreachable (e.g. destroyed manually), keep going so Terraform destroy still
# completes.
# Requires aws, kubectl, and helm on the machine running Terraform.
# ---------------------------------------------------------------------------

resource "terraform_data" "autoscaling_cleanup" {
  count = var.enable_autoscaling ? 1 : 0

  input = {
    cluster_name = aws_eks_cluster.nim.name
    region       = var.region
  }

  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      aws eks update-kubeconfig \
        --name "${self.input.cluster_name}" \
        --region "${self.input.region}" 2>/dev/null || true

      # Uninstall in reverse install order. DCGM (DaemonSet, no dependents) first.
      # Then kube-prometheus-stack — drains Prometheus PVCs before namespace delete.
      # Then KEDA — leave for last so ScaledObjects in other namespaces (if any
      # remain) don't get orphaned before their controller is gone.
      helm uninstall dcgm-exporter --namespace monitoring --wait --timeout 5m 2>/dev/null || true
      helm uninstall kps           --namespace monitoring --wait --timeout 10m 2>/dev/null || true
      helm uninstall keda          --namespace keda       --wait --timeout 5m 2>/dev/null || true

      kubectl delete namespace monitoring --wait=true --timeout=5m 2>/dev/null || true
      kubectl delete namespace keda       --wait=true --timeout=5m 2>/dev/null || true

      exit 0
    EOT
  }

  depends_on = [aws_eks_cluster.nim]
}
