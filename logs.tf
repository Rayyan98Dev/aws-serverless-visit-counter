resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/visit-counter"
  retention_in_days = 7
}