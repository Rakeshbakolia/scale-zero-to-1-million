# Phase 1: single EC2 (Go API) + RDS PostgreSQL — no ALB

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "scale-zero-to-million"
}

variable "scaling_phase" {
  type        = number
  default     = 1
  description = "0=none, 1=single EC2+RDS, 2=+ALB+ASG, 3=+RDS read replica, 4=+ElastiCache Redis, 5=+CloudFront+S3 frontend, 6=+CloudWatch dashboard+alarms, 7=data scale (~1M rows, keyset list), 8=wrap-up (tags only; use teardown.sh)"
}

variable "asg_min_size" {
  type        = number
  default     = 1
  description = "Phase 2 ASG minimum instances (use 2 to demo failover)"
}

variable "asg_max_size" {
  type        = number
  default     = 2
  description = "Phase 2 ASG maximum instances"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "api_port" {
  type    = number
  default = 8080
}

# Restrict to your IP for SSH/API in production; 0.0.0.0/0 is lab-only.
variable "allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed to reach API and SSH on EC2"
}

variable "admin_api_key" {
  type        = string
  sensitive   = true
  description = "X-Admin-Key for GET /api/v1/users"
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Optional existing EC2 key pair name in AWS; if empty, Terraform creates a new key pair"
}

variable "ec2_key_name" {
  type        = string
  default     = ""
  description = "Use existing AWS key pair name instead of generating one (set ssh_public_key path via deploy script)"
}

locals {
  enabled = var.scaling_phase >= 1
  phase2  = var.scaling_phase >= 2
  phase3  = var.scaling_phase >= 3
  phase4  = var.scaling_phase >= 4
  phase5  = var.scaling_phase >= 5
  phase6  = var.scaling_phase >= 6
  name    = var.project_name
  tags = {
    Project = local.name
    Phase   = local.enabled ? tostring(var.scaling_phase) : "0"
  }
  cors_origins = local.phase5 ? "http://localhost:5173,https://${aws_cloudfront_distribution.frontend[0].domain_name}" : "http://localhost:5173"
}

provider "aws" {
  region = var.aws_region
}

resource "random_password" "db" {
  count   = local.enabled ? 1 : 0
  length  = 32
  special = false
}

resource "tls_private_key" "ssh" {
  count     = local.enabled && var.ec2_key_name == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated" {
  count      = local.enabled && var.ec2_key_name == "" ? 1 : 0
  key_name   = "${local.name}-phase1"
  public_key = tls_private_key.ssh[0].public_key_openssh
  tags       = local.tags
}

resource "local_sensitive_file" "ssh_private_key" {
  count           = local.enabled && var.ec2_key_name == "" ? 1 : 0
  content         = tls_private_key.ssh[0].private_key_pem
  filename        = "${path.module}/.terraform/${local.name}-phase1.pem"
  file_permission = "0600"
}

data "aws_vpc" "default" {
  count   = local.enabled ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = local.enabled ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

resource "aws_security_group" "alb" {
  count       = local.phase2 ? 1 : 0
  name        = "${local.name}-alb"
  description = "ALB for API"
  vpc_id      = data.aws_vpc.default[0].id

  ingress {
    description = "HTTP to ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "api" {
  count       = local.enabled ? 1 : 0
  name        = "${local.name}-api"
  description = "EC2 API server"
  vpc_id      = data.aws_vpc.default[0].id

  dynamic "ingress" {
    for_each = local.phase2 ? [1] : []
    content {
      description     = "API from ALB"
      from_port       = var.api_port
      to_port         = var.api_port
      protocol        = "tcp"
      security_groups = [aws_security_group.alb[0].id]
    }
  }

  dynamic "ingress" {
    for_each = local.phase2 ? [] : [1]
    content {
      description = "API direct (Phase 1)"
      from_port   = var.api_port
      to_port     = var.api_port
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_security_group" "rds" {
  count       = local.enabled ? 1 : 0
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL"
  vpc_id      = data.aws_vpc.default[0].id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.api[0].id]
  }
  tags = local.tags
}

resource "aws_db_subnet_group" "main" {
  count      = local.enabled ? 1 : 0
  name       = "${local.name}-db"
  subnet_ids = data.aws_subnets.default[0].ids
  tags       = local.tags
}

resource "aws_db_instance" "primary" {
  count                  = local.enabled ? 1 : 0
  identifier             = "${local.name}-pg"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = "scalelab"
  username               = "scalelab"
  password               = random_password.db[0].result
  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  publicly_accessible    = false
  skip_final_snapshot     = true
  deletion_protection     = false
  # Read replicas require automated backups on the source (min 1 day).
  backup_retention_period = local.phase3 ? 1 : 0
  apply_immediately       = local.phase3
  tags                    = local.tags
}

# RDS rejects read-replica create until the source has finished enabling backups
# (first automated backup). Same-apply create races ModifyDBInstance; wait after retention > 0.
resource "time_sleep" "wait_primary_automated_backups" {
  count = local.phase3 ? 1 : 0

  create_duration = "10m"

  triggers = {
    primary_id              = aws_db_instance.primary[0].id
    backup_retention_period = aws_db_instance.primary[0].backup_retention_period
  }

  depends_on = [aws_db_instance.primary]
}

resource "aws_db_instance" "replica" {
  count                   = local.phase3 ? 1 : 0
  identifier              = "${local.name}-pg-replica"
  replicate_source_db     = aws_db_instance.primary[0].identifier
  instance_class          = var.db_instance_class
  vpc_security_group_ids  = [aws_security_group.rds[0].id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  tags                    = local.tags

  depends_on = [time_sleep.wait_primary_automated_backups]
}

resource "aws_security_group" "redis" {
  count       = local.phase4 ? 1 : 0
  name        = "${local.name}-redis"
  description = "ElastiCache Redis"
  vpc_id      = data.aws_vpc.default[0].id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.api[0].id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  count      = local.phase4 ? 1 : 0
  name       = "${local.name}-redis"
  subnet_ids = data.aws_subnets.default[0].ids
  tags       = local.tags
}

resource "aws_elasticache_cluster" "redis" {
  count                = local.phase4 ? 1 : 0
  cluster_id           = "${local.name}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis[0].name
  security_group_ids   = [aws_security_group.redis[0].id]
  tags                 = local.tags
}

resource "aws_s3_bucket" "frontend" {
  count         = local.phase5 ? 1 : 0
  bucket        = "${local.name}-web-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  count                   = local.phase5 ? 1 : 0
  bucket                  = aws_s3_bucket.frontend[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "frontend" {
  count                             = local.phase5 ? 1 : 0
  name                              = "${local.name}-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "frontend" {
  count               = local.phase5 ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "${local.name} UI + /api proxy"
  tags                = local.tags

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend[0].bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend[0].id
  }

  origin {
    origin_id = "alb-api"
    domain_name = aws_lb.api[0].dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
  }

  # Legacy forwarded_values avoids managed origin-request policy IDs (some accounts/API paths 404 them).
  ordered_cache_behavior {
    path_pattern           = "/api/*"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "alb-api"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0

    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  count  = local.phase5 ? 1 : 0
  bucket = aws_s3_bucket.frontend[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.frontend[0].arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend[0].arn
        }
      }
    }]
  })
}

resource "aws_iam_role" "ec2" {
  count = local.enabled ? 1 : 0
  name  = "${local.name}-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = local.enabled ? 1 : 0
  role       = aws_iam_role.ec2[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_s3_bucket" "artifacts" {
  count         = local.phase2 ? 1 : 0
  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                   = local.phase2 ? 1 : 0
  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role_policy" "ec2_artifacts" {
  count = local.phase2 ? 1 : 0
  name  = "${local.name}-s3-artifacts"
  role  = aws_iam_role.ec2[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.artifacts[0].arn}/api/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  count = local.enabled ? 1 : 0
  name  = "${local.name}-ec2"
  role  = aws_iam_role.ec2[0].name
}

resource "aws_ssm_parameter" "admin_key" {
  count = local.enabled ? 1 : 0
  name  = "/${local.name}/admin_api_key"
  type  = "SecureString"
  value = var.admin_api_key
  tags  = local.tags
}

resource "aws_ssm_parameter" "database_url" {
  count = local.enabled ? 1 : 0
  name  = "/${local.name}/database_url"
  type  = "SecureString"
  value = "postgres://scalelab:${random_password.db[0].result}@${aws_db_instance.primary[0].address}:5432/scalelab?sslmode=require"
  tags  = local.tags
}

resource "aws_ssm_parameter" "database_replica_url" {
  count = local.phase3 ? 1 : 0
  name  = "/${local.name}/database_replica_url"
  type  = "SecureString"
  value = "postgres://scalelab:${random_password.db[0].result}@${aws_db_instance.replica[0].address}:5432/scalelab?sslmode=require"
  tags  = local.tags
}

resource "aws_ssm_parameter" "redis_url" {
  count = local.phase4 ? 1 : 0
  name  = "/${local.name}/redis_url"
  type  = "SecureString"
  value = "redis://${aws_elasticache_cluster.redis[0].cache_nodes[0].address}:6379/0"
  tags  = local.tags
}

data "aws_ami" "al2023" {
  count       = local.enabled ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-kernel-6.1-x86_64"]
  }
}

resource "aws_instance" "api" {
  count                       = local.enabled && !local.phase2 ? 1 : 0
  ami                         = data.aws_ami.al2023[0].id
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.api[0].id]
  iam_instance_profile        = aws_iam_instance_profile.ec2[0].name
  key_name                    = var.ec2_key_name != "" ? var.ec2_key_name : aws_key_pair.generated[0].key_name
  associate_public_ip_address = true

  user_data = base64encode(templatefile("${path.module}/scripts/ec2-user-data.sh", {
    project_name     = local.name
    api_port         = var.api_port
    aws_region       = var.aws_region
    cors_origins     = local.cors_origins
    artifacts_bucket = ""
  }))

  tags = merge(local.tags, { Name = "${local.name}-api" })

  depends_on = [aws_db_instance.primary]
}

resource "aws_launch_template" "api" {
  count         = local.phase2 ? 1 : 0
  name_prefix   = "${local.name}-api-"
  image_id      = data.aws_ami.al2023[0].id
  instance_type = var.instance_type
  key_name      = var.ec2_key_name != "" ? var.ec2_key_name : aws_key_pair.generated[0].key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2[0].name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.api[0].id]
    device_index                = 0
  }

  user_data = base64encode(templatefile("${path.module}/scripts/ec2-user-data.sh", {
    project_name     = local.name
    api_port         = var.api_port
    aws_region       = var.aws_region
    cors_origins     = local.cors_origins
    artifacts_bucket = aws_s3_bucket.artifacts[0].bucket
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-api" })
  }

  depends_on = [aws_db_instance.primary]
}

resource "aws_lb" "api" {
  count              = local.phase2 ? 1 : 0
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = data.aws_subnets.default[0].ids
  tags               = local.tags
}

resource "aws_lb_target_group" "api" {
  count       = local.phase2 ? 1 : 0
  name        = "${local.name}-api"
  port        = var.api_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default[0].id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    matcher             = "200"
  }

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  count             = local.phase2 ? 1 : 0
  load_balancer_arn = aws_lb.api[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api[0].arn
  }
}

resource "aws_autoscaling_group" "api" {
  count                     = local.phase2 ? 1 : 0
  name                      = "${local.name}-api"
  desired_capacity          = var.asg_min_size
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  vpc_zone_identifier       = data.aws_subnets.default[0].ids
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.api[0].id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.api[0].arn]

  tag {
    key                 = "Name"
    value               = "${local.name}-api"
    propagate_at_launch = true
  }
  tag {
    key                 = "Project"
    value               = local.name
    propagate_at_launch = true
  }
  tag {
    key                 = "Phase"
    value               = local.tags.Phase
    propagate_at_launch = true
  }
}

resource "aws_cloudwatch_dashboard" "ops" {
  count          = local.phase6 && local.phase2 ? 1 : 0
  dashboard_name = "${local.name}-ops"
  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 2
          properties = {
            markdown = "# ${local.name} — Phase 6 observability\nALB · ASG · RDS · Redis · replica lag (when enabled). Run soak: `k6 run loadtests/k6/mixed.js`."
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "ALB target response time (p95)"
            period  = 60
            metrics = [
              ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.api[0].arn_suffix, { stat = "p95" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            view    = "timeSeries"
            stacked = false
            region  = var.aws_region
            title   = "ALB requests & target 5xx"
            period  = 60
            metrics = [
              ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.api[0].arn_suffix, { stat = "Sum", id = "req" }],
              [".", "HTTPCode_Target_5XX_Count", ".", ".", { stat = "Sum", id = "5xx", yAxis = "right" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 8
          height = 6
          properties = {
            view   = "timeSeries"
            region = var.aws_region
            title  = "ASG in-service instances"
            period = 60
            metrics = [
              ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.api[0].name, { stat = "Average" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 8
          width  = 8
          height = 6
          properties = {
            view   = "timeSeries"
            region = var.aws_region
            title  = "RDS primary CPU & connections"
            period = 60
            metrics = [
              ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary[0].identifier, { stat = "Average", id = "cpu" }],
              [".", "DatabaseConnections", ".", ".", { stat = "Average", id = "conn", yAxis = "right" }],
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 8
          width  = 8
          height = 6
          properties = {
            view   = "timeSeries"
            region = var.aws_region
            title  = "ElastiCache Redis CPU"
            period = 60
            metrics = [
              ["AWS/ElastiCache", "CPUUtilization", "CacheClusterId", aws_elasticache_cluster.redis[0].cluster_id, { stat = "Average" }],
            ]
          }
        },
      ],
      local.phase3 ? [
        {
          type   = "metric"
          x      = 0
          y      = 14
          width  = 12
          height = 6
          properties = {
            view   = "timeSeries"
            region = var.aws_region
            title  = "RDS read replica lag (seconds)"
            period = 60
            metrics = [
              ["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", aws_db_instance.replica[0].identifier, { stat = "Maximum" }],
            ]
          }
        },
      ] : []
    )
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  count               = local.phase6 && local.phase2 ? 1 : 0
  alarm_name          = "${local.name}-alb-target-5xx"
  alarm_description   = "ALB target 5xx sum > 10 in 5m (lab threshold)"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = aws_lb.api[0].arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count               = local.phase6 ? 1 : 0
  alarm_name          = "${local.name}-rds-primary-cpu"
  alarm_description   = "RDS primary CPU > 80% for 15m"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.primary[0].identifier
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  count               = local.phase6 && local.phase3 ? 1 : 0
  alarm_name          = "${local.name}-rds-replica-lag"
  alarm_description   = "Read replica lag > 60s"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 60
  treat_missing_data  = "notBreaching"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.replica[0].identifier
  }
}

output "phase" {
  value = var.scaling_phase
}

output "api_base_url" {
  value = local.phase5 ? "https://${aws_cloudfront_distribution.frontend[0].domain_name}" : (
    local.phase2 ? "http://${aws_lb.api[0].dns_name}" : (
      local.enabled ? "http://${aws_instance.api[0].public_ip}:${var.api_port}" : null
    )
  )
  description = "Phase 5+: CloudFront (UI + /api/*). Phase 2–4: ALB HTTP. Set VITE_API_BASE_URL for frontend build."
}

output "frontend_url" {
  value       = local.phase5 ? "https://${aws_cloudfront_distribution.frontend[0].domain_name}" : null
  description = "React app on CloudFront"
}

output "frontend_bucket" {
  value = local.phase5 ? aws_s3_bucket.frontend[0].bucket : null
}

output "cloudfront_distribution_id" {
  value = local.phase5 ? aws_cloudfront_distribution.frontend[0].id : null
}

output "alb_api_url" {
  value       = local.phase2 ? "http://${aws_lb.api[0].dns_name}" : null
  description = "Direct ALB URL (k6 / debugging); Phase 5 browsers should use frontend_url"
}

output "alb_dns_name" {
  value       = local.phase2 ? aws_lb.api[0].dns_name : null
  description = "Phase 2 load balancer DNS"
}

output "ec2_public_ip" {
  value = local.enabled && !local.phase2 ? aws_instance.api[0].public_ip : null
}

output "artifacts_bucket" {
  value = local.phase2 ? aws_s3_bucket.artifacts[0].bucket : null
}

output "rds_address" {
  value     = local.enabled ? aws_db_instance.primary[0].address : null
  sensitive = true
}

output "rds_replica_address" {
  value     = local.phase3 ? aws_db_instance.replica[0].address : null
  sensitive = true
}

output "redis_endpoint" {
  value     = local.phase4 ? aws_elasticache_cluster.redis[0].cache_nodes[0].address : null
  sensitive = true
}

output "ssh_private_key_path" {
  value       = local.enabled && var.ec2_key_name == "" ? local_sensitive_file.ssh_private_key[0].filename : null
  description = "ssh -i <path> ec2-user@<ec2_public_ip>"
}

output "deploy_command" {
  value = local.enabled ? "cd scripts && ./deploy-api.sh" : null
}

output "project_name" {
  value = local.name
}

output "cloudwatch_dashboard_name" {
  value       = local.phase6 && local.phase2 ? aws_cloudwatch_dashboard.ops[0].dashboard_name : null
  description = "CloudWatch dashboard (Phase 6)"
}

output "cloudwatch_dashboard_url" {
  value = local.phase6 && local.phase2 ? "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.ops[0].dashboard_name}" : null
  description = "Open in AWS Console"
}
