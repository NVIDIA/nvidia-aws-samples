resource "aws_security_group" "cluster" {
  region      = var.region
  name        = "${var.name_prefix}-eks-cluster"
  description = "EKS cluster SG - used by Auto Mode nodes and CodeBuild VPC placement"
  vpc_id      = var.vpc_id

  # Revoke all rules before deleting — prevents "DependencyViolation" when
  # other SGs reference this one during destroy.
  revoke_rules_on_delete = true

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (NAT/internet access for NGC pulls, ECR, S3)"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-eks-cluster" })
}

resource "aws_security_group_rule" "cluster_self_ingress" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.cluster.id
  description       = "Allow node-to-node and CodeBuild-to-API communication within the SG"
}

# Optional: allow developer workstations / VPN / bastion hosts to reach the API server
resource "aws_security_group_rule" "cluster_external_ingress" {
  count = var.allowed_cidr_blocks != null ? 1 : 0

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.cluster.id
  description       = "Allow kubectl access from specified CIDR blocks (developers, VPN, bastion)"
}
