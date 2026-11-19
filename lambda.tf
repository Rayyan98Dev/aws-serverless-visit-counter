data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/src/app.py"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_lambda_function" "counter" {
  function_name = "visit-counter"
  role          = aws_iam_role.lambda.arn
  handler       = "app.handler"
  runtime       = "python3.13"

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  memory_size                    = 128
  timeout                        = 5
  reserved_concurrent_executions = 2

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.visits.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
}

resource "aws_lambda_function_url" "counter" {
  function_name      = aws_lambda_function.counter.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  function_name          = aws_lambda_function.counter.function_name
  principal              = "*"
  action                 = "lambda:InvokeFunctionUrl"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "invoke" {
  function_name            = aws_lambda_function.counter.function_name
  principal                = "*"
  action                   = "lambda:InvokeFunction"
  invoked_via_function_url = true
}

output "url" {
  value = aws_lambda_function_url.counter.function_url
}