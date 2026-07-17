data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.nim.identity[0].oidc[0].issuer
}
