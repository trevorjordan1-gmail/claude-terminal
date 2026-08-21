data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "asp-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "asp-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags                    = { Name = "asp-public" }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  availability_zone = local.az_a
  tags              = { Name = "asp-private-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  availability_zone = local.az_b
  tags              = { Name = "asp-private-b" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "asp-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---- fck-nat: NAT on a t4g.nano instead of a managed NAT gateway ----

data "aws_ami" "fcknat" {
  most_recent = true
  owners      = ["568608671756"]
  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-ebs"]
  }
}

resource "aws_security_group" "nat" {
  name        = "asp-nat"
  description = "fck-nat: forward anything from inside the VPC"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "asp-nat" }
}

resource "aws_instance" "nat" {
  ami                    = data.aws_ami.fcknat.id
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nat.id]
  source_dest_check      = false
  tags                   = { Name = "asp-nat", Role = "nat" }
}

# The tenant's egress identity. Every terminal in the private subnets leaves
# through this one address, so it is what a customer firewall, a DNS filter, a
# vendor API allow-list or a conditional-access rule will be pinned to.
#
# Without it the NAT carries an auto-assigned public IPv4, which looks static
# right up until the instance is stopped or replaced — and then every
# allow-list built on it fails, quietly and everywhere at once.
#
# It is free to fix: AWS charges $0.005/hr for ALL in-use public IPv4,
# auto-assigned or Elastic, so an attached EIP costs exactly what the random
# address already cost. (An UNattached one costs the same again — release it
# if this NAT is ever torn down.)
resource "aws_eip" "nat" {
  instance = aws_instance.nat.id
  domain   = "vpc"
  tags     = { Name = "asp-nat-egress" }
}

# S3 without a bandwidth bill. Terminals live in private subnets, so every
# script download, status marker and backup upload otherwise egresses through
# the NAT instance — and about half of it crosses an AZ boundary on the way
# ($0.01/GB each direction). Same-region S3 transfer is free; it is the PATH
# that costs. A gateway endpoint keeps the traffic inside the VPC.
#
# Gateway endpoints are free: no hourly charge and no per-GB charge (unlike
# interface endpoints). There is no reason for a tenant not to have this.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.public.id,
  ]
  tags = { Name = "asp-s3" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.nat.primary_network_interface_id
  }
  tags = { Name = "asp-private" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}
