# VPC
resource "aws_vpc" "tfe" {
  cidr_block = var.vpc_cidr

  tags = {
    Name = "${var.environment_name}-vpc"
  }
}

# Public Subnet #1
resource "aws_subnet" "tfe_public" {
  availability_zone = "${var.region}b"
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  vpc_id            = aws_vpc.tfe.id

  tags = {
    Name = "${var.environment_name}-subnet-public"
  }
}

# Private Subnet #1
resource "aws_subnet" "tfe_private1" {
  availability_zone = "${var.region}b"
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 10)
  vpc_id            = aws_vpc.tfe.id

  tags = {
    Name = "${var.environment_name}-subnet-private1"
  }
}

# Private Subnet #2
resource "aws_subnet" "tfe_private2" {
  availability_zone = "${var.region}c"
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 11)
  vpc_id            = aws_vpc.tfe.id

  tags = {
    Name = "${var.environment_name}-subnet-private2"
  }
}

# IGW (Internet Gateway)
resource "aws_internet_gateway" "tfe_igw" {
  vpc_id = aws_vpc.tfe.id

  tags = {
    Name = "${var.environment_name}-igw"
  }
}

# Link IGW with default VPC Route Table
resource "aws_default_route_table" "tfe" {
  default_route_table_id = aws_vpc.tfe.default_route_table_id

  route {
    cidr_block = local.all_ips
    gateway_id = aws_internet_gateway.tfe_igw.id
  }

  tags = {
    Name = "${var.environment_name}-rtb"
  }
}

# Key Pair
resource "tls_private_key" "rsa-4096" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "tfe" {
  key_name   = "${var.environment_name}-keypair"
  public_key = tls_private_key.rsa-4096.public_key_openssh
}

resource "local_file" "tfesshkey" {
  content         = tls_private_key.rsa-4096.private_key_pem
  filename        = "${path.module}/tfesshkey.pem"
  file_permission = "0600"
}

# Security Group
resource "aws_security_group" "tfe_sg" {
  name   = "${var.environment_name}-sg"
  vpc_id = aws_vpc.tfe.id

  tags = {
    Name = "${var.environment_name}-sg"
  }
}

resource "aws_security_group_rule" "allow_ssh_inbound" {
  cidr_blocks       = [local.all_ips]
  from_port         = "22"
  protocol          = "tcp"
  security_group_id = aws_security_group.tfe_sg.id
  to_port           = "22"
  type              = "ingress"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  cidr_blocks       = [local.all_ips]
  from_port         = "80"
  protocol          = "tcp"
  security_group_id = aws_security_group.tfe_sg.id
  to_port           = "80"
  type              = "ingress"
}

resource "aws_security_group_rule" "allow_https_inbound" {
  cidr_blocks       = [local.all_ips]
  from_port         = "443"
  protocol          = "tcp"
  security_group_id = aws_security_group.tfe_sg.id
  to_port           = "443"
  type              = "ingress"
}

resource "aws_security_group_rule" "allow_postgresql_inbound_vpc" {
  cidr_blocks       = [aws_vpc.tfe.cidr_block]
  from_port         = "5432"
  protocol          = "tcp"
  security_group_id = aws_security_group.tfe_sg.id
  to_port           = "5432"
  type              = "ingress"
}

resource "aws_security_group_rule" "allow_all_outbound" {
  cidr_blocks       = [local.all_ips]
  from_port         = "0"
  protocol          = "-1"
  security_group_id = aws_security_group.tfe_sg.id
  to_port           = "0"
  type              = "egress"
}

# EC2
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "tfe" {
  ami                    = data.aws_ami.ubuntu.image_id
  iam_instance_profile   = aws_iam_instance_profile.tfe_profile.name
  instance_type          = var.instance_type
  key_name               = aws_key_pair.tfe.key_name
  subnet_id              = aws_subnet.tfe_public.id
  vpc_security_group_ids = [aws_security_group.tfe_sg.id]

  user_data = templatefile("${path.module}/scripts/cloud-init.tpl", {
    database_name       = var.database_name
    postgresql_fqdn     = aws_db_instance.tfe.address
    postgresql_password = var.postgresql_password
    postgresql_user     = var.postgresql_user
    region              = var.region
    route53_subdomain   = var.route53_subdomain
    route53_zone        = var.route53_zone
    s3_bucket           = aws_s3_bucket.tfe_files.id
    tfe_license         = var.tfe_license
    tfe_password        = var.tfe_password
    tfe_release         = var.tfe_release
  })

  root_block_device {
    volume_size = 50
  }

  tags = {
    Name = "${var.environment_name}-ec2"
  }
}

# Public IP
resource "aws_eip" "eip_tfe" {
  vpc = true

  tags = {
    Name = "${var.environment_name}-eip"
  }
}

resource "aws_eip_association" "eip_assoc" {
  allocation_id = aws_eip.eip_tfe.id
  instance_id   = aws_instance.tfe.id
}

# DNS
data "aws_route53_zone" "selected" {
  name         = var.route53_zone
  private_zone = false
}

resource "aws_route53_record" "www" {
  name    = local.fqdn
  records = [aws_eip.eip_tfe.public_ip]
  ttl     = "300"
  type    = "A"
  zone_id = data.aws_route53_zone.selected.zone_id
}

# SSL certificate
resource "tls_private_key" "cert_private_key" {
  algorithm = "RSA"
}

resource "acme_registration" "registration" {
  account_key_pem = tls_private_key.cert_private_key.private_key_pem
  email_address   = var.cert_email
}

resource "acme_certificate" "certificate" {
  account_key_pem = acme_registration.registration.account_key_pem
  common_name     = local.fqdn

  dns_challenge {
    provider = "route53"

    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.selected.zone_id
    }
  }
}

resource "aws_acm_certificate" "cert" {
  certificate_body  = acme_certificate.certificate.certificate_pem
  certificate_chain = acme_certificate.certificate.issuer_pem
  private_key       = acme_certificate.certificate.private_key_pem
}

# S3 bucket
resource "aws_s3_bucket" "tfe_files" {
  bucket = "${var.environment_name}-bucket"

  tags = {
    Name = "${var.environment_name}-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "tfe_files" {
  bucket = aws_s3_bucket.tfe_files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "certificate" {
  bucket  = aws_s3_bucket.tfe_files.bucket
  content = "${acme_certificate.certificate.certificate_pem}${acme_certificate.certificate.issuer_pem}"
  key     = "cert.pem"
}

resource "aws_s3_object" "private_key" {
  bucket  = aws_s3_bucket.tfe_files.bucket
  content = acme_certificate.certificate.private_key_pem
  key     = "key.pem"
}

# IAM
resource "aws_iam_instance_profile" "tfe_profile" {
  name = "${var.environment_name}-profile"
  role = aws_iam_role.tfe_s3_role.name
}

resource "aws_iam_role" "tfe_s3_role" {
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "ec2.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
  name = "${var.environment_name}-role"

  tags = {
    tag-key = "${var.environment_name}-role"
  }
}

resource "aws_iam_role_policy_attachment" "test-attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.tfe_s3_role.name
}

# RDS
resource "aws_db_instance" "tfe" {
  allocated_storage      = 50
  db_name                = var.database_name
  db_subnet_group_name   = aws_db_subnet_group.tfe.name
  engine                 = "postgres"
  engine_version         = "14.5"
  identifier             = "${var.environment_name}-postgres"
  instance_class         = "db.m5.large"
  multi_az               = false
  password               = var.postgresql_password
  skip_final_snapshot    = true
  username               = var.postgresql_user
  vpc_security_group_ids = [aws_security_group.tfe_sg.id]

  tags = {
    Name = "${var.environment_name}-postgres"
  }
}

resource "aws_db_subnet_group" "tfe" {
  name       = "${var.environment_name}-subnetgroup"
  subnet_ids = [aws_subnet.tfe_private1.id, aws_subnet.tfe_private2.id]

  tags = {
    Name = "${var.environment_name}-subnetgroup"
  }
}