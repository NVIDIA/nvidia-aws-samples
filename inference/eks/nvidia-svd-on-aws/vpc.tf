locals {
  # AZ IDs (e.g. use1-az1) are stable across AWS accounts; AZ names (us-east-1a) are not —
  # us-east-1a in one account can be a different physical AZ than us-east-1a in another.
  # Using zone_ids ensures the subnets land in the same physical AZs every time.
  #
  # 4 AZs (not 2): g6e is only present in a subset of AZs in each region. With 2 AZs you
  # may land in two that both lack g6e capacity → pod stuck Pending with
  # InsufficientInstanceCapacity. 4 AZs maximizes the chance Karpenter finds a healthy AZ.
  # See README "Multi-GPU and scaling" → "Diversify AZs within a region".
  az_ids   = slice(data.aws_availability_zones.available.zone_ids, 0, 4)
  vpc_cidr = "10.0.0.0/16"
}

resource "aws_vpc" "main" {
  region               = data.aws_region.current.region
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "svd-eks-vpc" }
}

resource "aws_subnet" "public" {
  count = length(local.az_ids)

  region                  = data.aws_region.current.region
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(local.vpc_cidr, 8, count.index)
  availability_zone_id    = local.az_ids[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "svd-eks-public-${count.index}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  count = length(local.az_ids)

  region               = data.aws_region.current.region
  vpc_id               = aws_vpc.main.id
  cidr_block           = cidrsubnet(local.vpc_cidr, 8, count.index + 10)
  availability_zone_id = local.az_ids[count.index]

  tags = {
    Name                              = "svd-eks-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_internet_gateway" "main" {
  region = data.aws_region.current.region
  vpc_id = aws_vpc.main.id
  tags   = { Name = "svd-eks-igw" }
}

resource "aws_eip" "nat" {
  region = data.aws_region.current.region
  domain = "vpc"
  tags   = { Name = "svd-eks-nat-eip" }

  depends_on = [aws_internet_gateway.main]
}

# Single shared NAT gateway in public[0]. Subnets are free; per-AZ NAT gateways are not.
resource "aws_nat_gateway" "main" {
  region        = data.aws_region.current.region
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "svd-eks-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  region = data.aws_region.current.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "svd-eks-public-rt" }
}

resource "aws_route_table_association" "public" {
  count = length(local.az_ids)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  region = data.aws_region.current.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "svd-eks-private-rt" }
}

resource "aws_route_table_association" "private" {
  count = length(local.az_ids)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
