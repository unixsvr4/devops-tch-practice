terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "tch-terraform-state"
    key            = "us-east-1/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tch-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = "us-east-1"
  alias  = "primary"
}

provider "aws" {
  region = "us-west-2"
  alias  = "dr"
}

# Primary RDS with Multi-AZ
resource "aws_db_instance" "primary" {
  provider              = aws.primary
  identifier            = "tch-payments-primary"
  engine                = "postgres"
  instance_class        = "db.r6g.xlarge"
  multi_az              = true           # automatic failover within region
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn
  backup_retention_period = 7
  deletion_protection   = true
}

# Cross-region read replica (DR)
resource "aws_db_instance" "replica" {
  provider            = aws.dr
  identifier          = "tch-payments-dr"
  replicate_source_db = aws_db_instance.primary.arn
  instance_class      = "db.r6g.xlarge"
  storage_encrypted   = true
  kms_key_id          = aws_kms_key.rds_dr.arn
}

# Route53 health check + failover
resource "aws_route53_health_check" "primary" {
  fqdn              = "payments.us-east-1.tch.internal"
  port              = 443
  type              = "HTTPS"
  failure_threshold = 2
  request_interval  = 10
}

resource "aws_route53_record" "payments_primary" {
  zone_id = var.hosted_zone_id
  name    = "payments.tch.internal"
  type    = "A"
  set_identifier = "primary"
  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.primary.id
  alias {
    name                   = aws_lb.primary.dns_name
    zone_id                = aws_lb.primary.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "payments_dr" {
  zone_id = var.hosted_zone_id
  name    = "payments.tch.internal"
  type    = "A"
  set_identifier = "secondary"
  failover_routing_policy { type = "SECONDARY" }
  alias {
    name                   = aws_lb.dr.dns_name
    zone_id                = aws_lb.dr.zone_id
    evaluate_target_health = true
  }
}

# KMS key for encryption at rest
resource "aws_kms_key" "rds" {
  description             = "RDS encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}
