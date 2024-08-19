data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  backup_bucket_name = var.s3_bucket_name != "" ? var.s3_bucket_name : format("%s-%s", var.resource_name_prefix, "backup")
}

# Generate the cloud-init user data

# Cloud-init configuration for Pritunl provisioning
data "cloudinit_config" "pritunl_userdata" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/user-data.tftpl",
      {
        aws_region          = data.aws_region.current.name
        s3_backup_bucket    = local.backup_bucket_name
        healthchecks_io_key = "/pritunl/${var.resource_name_prefix}/healthchecks-io-key"
      }
    )
  }

}

data "aws_iam_policy_document" "kms_policy" {
  statement {
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    actions   = ["kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["${aws_iam_role.role.arn}"]
    }
  }
}

data "aws_iam_policy_document" "iam_instance_role_policy" {
  statement {
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
      "s3:PutObject*",
      "s3:Get*",
      "s3:List*",
      "s3:DeleteObject",
      "ssm:GetParameters"
    ]
    resources = [
      "arn:aws:s3:::${local.backup_bucket_name}",
      "arn:aws:s3:::${local.backup_bucket_name}/*",
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/pritunl/${var.resource_name_prefix}/*"
    ]
  }

  statement {
    actions   = ["ec2messages:*", "cloudwatch:PutMetricData", "ec2:DescribeInstanceStatus", "ds:*", "logs:*"]
    resources = ["*"]
  }
}

# KMS Key
resource "aws_kms_key" "parameter_store" {
  description              = "Parameter store and backup key for ${var.resource_name_prefix}"
  policy                   = data.aws_iam_policy_document.kms_policy.json
  deletion_window_in_days  = 30
  enable_key_rotation      = true

  tags = merge(
    tomap({"Name" = format("%s-%s", var.resource_name_prefix, "parameter-store")}),
    var.tags,
  )
}

resource "aws_kms_alias" "parameter_store" {
  name          = "alias/${var.resource_name_prefix}-parameter-store"
  target_key_id = aws_kms_key.parameter_store.key_id
}

# EC2 IAM Role and Policies
resource "aws_iam_role" "role" {
  name = var.resource_name_prefix

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "policy" {
  name   = "${var.resource_name_prefix}-instance-policy"
  role   = aws_iam_role.role.id
  policy = data.aws_iam_policy_document.iam_instance_role_policy.json
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.resource_name_prefix}-instance"
  role = aws_iam_role.role.name
}

# Security Groups
resource "aws_security_group" "pritunl" {
  name        = "${var.resource_name_prefix}-vpn"
  description = "${var.resource_name_prefix}-vpn"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.internal_cidrs
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.whitelist_http
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.internal_cidrs
  }

  ingress {
    from_port   = 10000
    to_port     = 19999
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.internal_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    tomap({"Name" = format("%s-%s", var.resource_name_prefix, "vpn")}),
    var.tags,
  )
}

resource "aws_security_group" "allow_from_office" {
  name        = "${var.resource_name_prefix}-whitelist"
  description = "Allows SSH connections and HTTP(s) connections from office"
  vpc_id      = var.vpc_id

  # SSH access
  ingress {
    description = "Allow SSH access from select CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.whitelist
  }

  # HTTPS access
  ingress {
    description = "Allow HTTPS access from select CIDRs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.whitelist
  }

  # ICMP
  ingress {
    description = "Allow ICMPv4 from select CIDRs"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = var.whitelist
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    tomap({"Name" = format("%s-%s", var.resource_name_prefix, "whitelist")}),
    var.tags,
  )
}

# EC2 instance for Pritunl
resource "aws_instance" "pritunl" {
  ami               = var.ami_id
  instance_type     = var.instance_type
  key_name          = var.aws_key_name
  ebs_optimized     = var.ebs_optimized
  user_data_base64  = data.cloudinit_config.pritunl_userdata.rendered

  vpc_security_group_ids = [
    aws_security_group.pritunl.id,
    aws_security_group.allow_from_office.id,
  ]

  subnet_id            = var.public_subnet_id
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    kms_key_id            = var.kms_key_id
    encrypted             = true
    delete_on_termination = false  # Ensure the root volume is not deleted
  }

  tags = merge(
    tomap({"Name" = format("%s-%s", var.resource_name_prefix, "vpn")}),
    var.tags,
  )

  # Add patching options if enabled
  lifecycle {
    create_before_destroy = true
  }

  
}

resource "aws_eip" "pritunl" {
  instance = aws_instance.pritunl.id
  vpc      = true
}
