locals {
  # AZ IDs (use1-az1, ...) are stable across accounts; AZ names (us-east-1a, ...) are not.
  # See root README "Multi-AZ design for GPU capacity" for the rationale + AWS docs.
  az_ids   = slice(data.aws_availability_zones.available.zone_ids, 0, 4)
  vpc_cidr = "10.0.0.0/16"
}

resource "aws_vpc" "main" {
  region               = data.aws_region.current.region
  cidr_block           = local.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "nim-eks-vpc" }
}

resource "aws_subnet" "public" {
  count = length(local.az_ids)

  region                  = data.aws_region.current.region
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(local.vpc_cidr, 8, count.index)
  availability_zone_id    = local.az_ids[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "nim-eks-public-${count.index}"
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
    Name                              = "nim-eks-private-${count.index}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_internet_gateway" "main" {
  region = data.aws_region.current.region
  vpc_id = aws_vpc.main.id
  tags   = { Name = "nim-eks-igw" }
}

resource "aws_eip" "nat" {
  region = data.aws_region.current.region
  domain = "vpc"
  tags   = { Name = "nim-eks-nat-eip" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  region        = data.aws_region.current.region
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "nim-eks-nat" }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  region = data.aws_region.current.region
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "nim-eks-public-rt" }
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

  tags = { Name = "nim-eks-private-rt" }
}

resource "aws_route_table_association" "private" {
  count = length(local.az_ids)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
