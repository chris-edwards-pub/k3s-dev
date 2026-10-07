# Nightly safety net: EventBridge Scheduler invokes a Lambda that stops every running
# instance tagged Project=<cluster_name>. Same effect as `./cluster.sh down`.

locals {
  auto_stop_count = var.auto_stop_enabled ? 1 : 0
  auto_stop_name  = "${var.cluster_name}-auto-stop"
}

data "archive_file" "auto_stop" {
  count       = local.auto_stop_count
  type        = "zip"
  source_file = "${path.module}/lambda/auto_stop.py"
  output_path = "${path.module}/.build/auto_stop.zip"
}

# --- Lambda ---

resource "aws_iam_role" "auto_stop" {
  count = local.auto_stop_count
  name  = local.auto_stop_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "auto_stop_logs" {
  count      = local.auto_stop_count
  role       = aws_iam_role.auto_stop[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "auto_stop" {
  count = local.auto_stop_count
  name  = "stop-tagged-instances"
  role  = aws_iam_role.auto_stop[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*" # DescribeInstances does not support resource-level permissions
      },
      {
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/Project" = var.cluster_name }
        }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "auto_stop" {
  count             = local.auto_stop_count
  name              = "/aws/lambda/${local.auto_stop_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "auto_stop" {
  count            = local.auto_stop_count
  function_name    = local.auto_stop_name
  description      = "Stops ${var.cluster_name} nodes nightly"
  role             = aws_iam_role.auto_stop[0].arn
  runtime          = "python3.13"
  handler          = "auto_stop.handler"
  filename         = data.archive_file.auto_stop[0].output_path
  source_code_hash = data.archive_file.auto_stop[0].output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      TAG_KEY   = "Project"
      TAG_VALUE = var.cluster_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.auto_stop,
    aws_iam_role_policy_attachment.auto_stop_logs,
  ]
}

# --- Schedule ---

resource "aws_iam_role" "auto_stop_scheduler" {
  count = local.auto_stop_count
  name  = "${local.auto_stop_name}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "auto_stop_scheduler" {
  count = local.auto_stop_count
  name  = "invoke-auto-stop"
  role  = aws_iam_role.auto_stop_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.auto_stop[0].arn
    }]
  })
}

resource "aws_scheduler_schedule" "auto_stop" {
  count                        = local.auto_stop_count
  name                         = local.auto_stop_name
  description                  = "Stop ${var.cluster_name} nodes nightly in case they were left running"
  schedule_expression          = var.auto_stop_schedule
  schedule_expression_timezone = var.auto_stop_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.auto_stop[0].arn
    role_arn = aws_iam_role.auto_stop_scheduler[0].arn
  }
}
