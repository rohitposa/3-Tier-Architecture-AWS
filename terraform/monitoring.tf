# ---------------------------------------------------------------
# AI alert analyzer:
#   CloudWatch Alarm -> SNS (alarms) -> Lambda -> Gemini API -> SNS (notify) -> Email
# ---------------------------------------------------------------

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-alarms"
}

resource "aws_sns_topic" "notify" {
  name = "${var.project_name}-ai-incident-summaries"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notify.arn
  protocol  = "email"
  endpoint  = var.alert_email # confirm the subscription from your inbox
}

resource "aws_ssm_parameter" "gemini_key" {
  name  = "/${var.project_name}/gemini/api_key"
  type  = "SecureString"
  value = var.gemini_api_key
}

# ---------- Lambda ----------
data "archive_file" "analyzer" {
  type        = "zip"
  source_file = "${path.module}/../ai-alert-analyzer/lambda_function.py"
  output_path = "${path.module}/build/alert_analyzer.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "analyzer" {
  name               = "${var.project_name}-alert-analyzer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "analyzer_logs" {
  role       = aws_iam_role.analyzer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "analyzer" {
  name = "least-privilege"
  role = aws_iam_role.analyzer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.gemini_key.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.notify.arn
      }
    ]
  })
}

resource "aws_lambda_function" "analyzer" {
  function_name    = "${var.project_name}-alert-analyzer"
  role             = aws_iam_role.analyzer.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.analyzer.output_path
  source_code_hash = data.archive_file.analyzer.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      GEMINI_SECRET_PARAM = aws_ssm_parameter.gemini_key.name
      GEMINI_MODEL        = var.gemini_model
      NOTIFY_TOPIC_ARN    = aws_sns_topic.notify.arn
      PROJECT_NAME        = var.project_name
    }
  }
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyzer.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alarms.arn
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.analyzer.arn
}

# ---------- CloudWatch alarms ----------
locals {
  alarms = {
    web-alb-5xx = {
      description = "Web ALB is returning 5xx errors"
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_ELB_5XX_Count"
      statistic   = "Sum"
      threshold   = 5
      operator    = "GreaterThanOrEqualToThreshold"
      evaluations = 1
      dimensions  = { LoadBalancer = aws_lb.web.arn_suffix }
    }
    app-alb-target-5xx = {
      description = "App servers are returning 5xx errors"
      namespace   = "AWS/ApplicationELB"
      metric      = "HTTPCode_Target_5XX_Count"
      statistic   = "Sum"
      threshold   = 5
      operator    = "GreaterThanOrEqualToThreshold"
      evaluations = 1
      dimensions  = { LoadBalancer = aws_lb.app.arn_suffix }
    }
    web-unhealthy-hosts = {
      description = "Unhealthy web targets behind the public ALB"
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      threshold   = 1
      operator    = "GreaterThanOrEqualToThreshold"
      evaluations = 2
      dimensions = {
        LoadBalancer = aws_lb.web.arn_suffix
        TargetGroup  = aws_lb_target_group.web.arn_suffix
      }
    }
    app-unhealthy-hosts = {
      description = "Unhealthy app targets behind the internal ALB"
      namespace   = "AWS/ApplicationELB"
      metric      = "UnHealthyHostCount"
      statistic   = "Maximum"
      threshold   = 1
      operator    = "GreaterThanOrEqualToThreshold"
      evaluations = 2
      dimensions = {
        LoadBalancer = aws_lb.app.arn_suffix
        TargetGroup  = aws_lb_target_group.app.arn_suffix
      }
    }
    app-asg-high-cpu = {
      description = "App tier average CPU above 80%"
      namespace   = "AWS/EC2"
      metric      = "CPUUtilization"
      statistic   = "Average"
      threshold   = 80
      operator    = "GreaterThanThreshold"
      evaluations = 2
      dimensions  = { AutoScalingGroupName = aws_autoscaling_group.app.name }
    }
    rds-high-cpu = {
      description = "RDS CPU above 80%"
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      statistic   = "Average"
      threshold   = 80
      operator    = "GreaterThanThreshold"
      evaluations = 2
      dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
    }
    rds-low-storage = {
      description = "RDS free storage below 2 GB"
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      statistic   = "Minimum"
      threshold   = 2147483648
      operator    = "LessThanThreshold"
      evaluations = 1
      dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${var.project_name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  evaluation_periods  = each.value.evaluations
  period              = 300
  dimensions          = each.value.dimensions
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}
