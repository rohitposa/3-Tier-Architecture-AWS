output "web_alb_dns" {
  description = "Open this URL in the browser"
  value       = "http://${aws_lb.web.dns_name}"
}

output "app_alb_dns" {
  value = aws_lb.app.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "alert_analyzer_lambda" {
  value = aws_lambda_function.analyzer.function_name
}
