resource "aws_ecr_repository" "nim" {
  region = var.region

  name                 = local.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, {
    Name = local.ecr_repo_name
  })
}

# ECR lifecycle policy.
#
# Rule 1 (always): expire untagged images after 14 days — cleans up intermediate
# layers from repeated builds. Always active regardless of ecr_image_retention_days.
#
# Rule 2 (variable-driven):
#   - ecr_image_retention_days = null (default): keep last 10 tagged images. Basic
#     protection against runaway tag accumulation, no time constraint.
#   - ecr_image_retention_days = N: expire ALL images (tagged + untagged) older than
#     N days. Handles the main orphan scenario: old {image}-{version}-base/shim tags
#     left behind after a NIM version bump. Each shim is ~10 GB.
resource "aws_ecr_lifecycle_policy" "nim" {
  region     = var.region
  repository = aws_ecr_repository.nim.name

  policy = var.ecr_image_retention_days != null ? jsonencode({
    rules = [
      local.ecr_untagged_expire_rule,
      {
        rulePriority = 2
        description  = "Expire all images older than ${var.ecr_image_retention_days} days"
        selection = {
          tagStatus   = "any"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_image_retention_days
        }
        action = { type = "expire" }
      }
    ]
    }) : jsonencode({
    rules = [
      local.ecr_untagged_expire_rule,
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
