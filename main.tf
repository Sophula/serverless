data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "archive_file" "LambdaZipFile" {
  type        = "zip"
  source_file = "${path.module}/src/LambdaFunction.py"
  output_path = "${path.module}/LambdaFunction.zip"
}

# Create an IAM role with an assume role policy, will allow the API Gateway to access other AWS services

resource "aws_iam_role" "APIGWRole" {
  assume_role_policy = <<POLICY
{
  "Version" : "2012-10-17",
  "Statement" : [
    {
      "Effect" : "Allow",
      "Principal" : {
        "Service" : "apigateway.amazonaws.com"
      },
      "Action" : "sts:AssumeRole"
    }
  ]
}
POLICY
}

# This policy will allow the user to put events into the default event bus

resource "aws_iam_policy" "APIGWPolicy" {
  policy = <<POLICY
{
  "Version" : "2012-10-17",
  "Statement" : [
    {
      "Effect" : "Allow",
      "Action" : [
        "events:PutEvents"
      ],
      "Resource" : "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/default"
    }
  ]
}
POLICY
}

# Allow IAM role to access the resources that are specified in the policy

resource "aws_iam_role_policy_attachment" "APIGWPolicyAttachment" {
  role       = aws_iam_role.APIGWRole.name
  policy_arn = aws_iam_policy.APIGWPolicy.arn
}

# Allow Lambda to access other AWS services

resource "aws_iam_role" "LambdaRole" {
  assume_role_policy = <<POLICY
{
  "Version" : "2012-10-17",
  "Statement" : [
    {
      "Effect" : "Allow",
      "Principal" : {
        "Service" : "lambda.amazonaws.com"
      },
      "Action" : "sts:AssumeRole"
    }
  ]
}
POLICY
}

# Allow lambda function to create log streams and put log events into the log group

resource "aws_iam_policy" "LambdaPolicy" {
  policy = <<POLICY
{
  "Version" : "2012-10-17",
  "Statement" : [
    {
      "Effect" : "Allow",
      "Action" : [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource" : "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${aws_lambda_function.LambdaFunction.function_name}:*:*"
    }
  ]
}
POLICY
}

# Attach lambda policy to the role

resource "aws_iam_role_policy_attachment" "LambdaPolicyAttachment" {
  role       = aws_iam_role.LambdaRole.name
  policy_arn = aws_iam_policy.LambdaPolicy.arn
}

# Create AWS API Gateway HTTP API to EventBridge

resource "aws_apigatewayv2_api" "ApiGatewayHTTPApi" {
  name          = "Terraform API Gateway HTTP API to EventBridge"
  protocol_type = "HTTP"
  body = jsonencode(
    {
      "openapi" : "3.0.1",
      "info" : {
        "title" : "API Gateway HTTP API to EventBridge"
      },
      "paths" : {
        "/" : {
          "post" : {
            "responses" : {
              "default" : {
                "description" : "EventBridge response"
              }
            },
            "x-amazon-apigateway-integration" : {
              "integrationSubtype" : "EventBridge-PutEvents",
              "credentials" : "${aws_iam_role.APIGWRole.arn}",
              "requestParameters" : {
                "Detail" : "$request.body.Detail",
                "DetailType" : "DetailType",
                "Source" : "university.apigw"
              },
              "payloadFormatVersion" : "1.0",
              "type" : "aws_proxy",
              "connectionType" : "INTERNET"
            }
          }
        }
      }
  })
}

# Create the Gateway Stage Resource

resource "aws_apigatewayv2_stage" "ApiGatewayHTTPApiStage" {
  api_id      = aws_apigatewayv2_api.ApiGatewayHTTPApi.id
  name        = "$default"
  auto_deploy = true

}

# Create the EventBridge (CloudWatch) Event Rule

resource "aws_cloudwatch_event_rule" "EventRule" {
  event_pattern = <<PATTERN
{
  "account": ["${data.aws_caller_identity.current.account_id}"],
  "source": ["university.apigw"]
}
PATTERN
}

# Link Lambda function to cloudwatch event rule, will allow lambda function to be triggered when the event rule is triggered

resource "aws_cloudwatch_event_target" "RuleTarget" {
  arn  = aws_lambda_function.LambdaFunction.arn
  rule = aws_cloudwatch_event_rule.EventRule.id
}

resource "aws_cloudwatch_log_group" "LogGroup" {
  name              = "/aws/lambda/${aws_lambda_function.LambdaFunction.function_name}"
  retention_in_days = 60
}

# Create lambda function resource

resource "aws_lambda_function" "LambdaFunction" {
  function_name    = "apigw-http-eventbridge-terraform-university-${data.aws_caller_identity.current.account_id}"
  filename         = data.archive_file.LambdaZipFile.output_path
  source_code_hash = filebase64sha256(data.archive_file.LambdaZipFile.output_path)
  role             = aws_iam_role.LambdaRole.arn
  handler          = "LambdaFunction.lambda_handler"
  runtime          = "python3.9"
  layers           = ["arn:aws:lambda:${data.aws_region.current.name}:017000801446:layer:AWSLambdaPowertoolsPython:15"]
}

# Create the lambda invocation permission resource

resource "aws_lambda_permission" "EventBridgeLambdaPermission" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.LambdaFunction.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.EventRule.arn
}

# Create an AWS Cognito User Pool

resource "aws_cognito_user_pool" "user_pool" {
  name                = "university-user-pool"
  username_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  # Required Standard Attributes

  schema {
    attribute_data_type = "String"
    mutable             = true
    name                = "email"
    required            = true
    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }

  schema {
    attribute_data_type = "String"
    mutable             = true
    name                = "given_name"
    required            = true
    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }

  schema {
    attribute_data_type = "String"
    mutable             = true
    name                = "family_name"
    required            = true
    string_attribute_constraints {
      min_length = 1
      max_length = 2048
    }
  }
}

# Create a Cognito User Pool Client
resource "aws_cognito_user_pool_client" "user_pool_client" {
  name            = "university-user-pool-client"
  user_pool_id    = aws_cognito_user_pool.user_pool.id
  generate_secret = true
}

# Create an API Gateway REST API
resource "aws_api_gateway_rest_api" "api" {
  name        = "university-api"
  description = "University REST API"
}

# Create a Cognito User Pool Authorizer
resource "aws_api_gateway_authorizer" "authorizer" {
  name                             = "university-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.api.id
  type                             = "COGNITO_USER_POOLS"
  provider_arns                    = [aws_cognito_user_pool.user_pool.arn]
  identity_source                  = "method.request.header.Authorization"
  authorizer_result_ttl_in_seconds = 300
}

# Create an API Gateway Resource
resource "aws_api_gateway_resource" "resource" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "university"
}

# Create an API Gateway Method
resource "aws_api_gateway_method" "method" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.resource.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

# Create an API Gateway Integration
resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.resource.id
  http_method             = aws_api_gateway_method.method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/${aws_lambda_function.LambdaFunction.arn}/invocations"
}

# Create an API Gateway Method Response
resource "aws_api_gateway_method_response" "response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method
  status_code = "200"
  response_models = {
    "application/json" = "Empty"
  }
}

# Create an API Gateway Integration Response
resource "aws_api_gateway_integration_response" "integration-Response" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.resource.id
  http_method = aws_api_gateway_method.method.http_method
  status_code = aws_api_gateway_method_response.response.status_code
  response_templates = {
    "application/json" = ""
  }
}

# Create an AWS WAF WebACL
resource "aws_wafv2_web_acl" "web_acl" {
  name        = "api-gateway-waf"
  description = "WebACL for API Gateway"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rule-1"
    priority = 1

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        rule_action_override {
          action_to_use {
            count {}
          }

          name = "SizeRestrictions_QUERYSTRING"
        }

        rule_action_override {
          action_to_use {
            count {}
          }

          name = "NoUserAgent_HEADER"
        }

        scope_down_statement {
          geo_match_statement {
            country_codes = ["GE"]
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "rule-metric-name"
      sampled_requests_enabled   = false
    }
  }

  tags = {
    Tag1 = "Value1"
    Tag2 = "Value2"
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "metric-name"
    sampled_requests_enabled   = false
  }
} 

/*
resource "aws_wafv2_web_acl" "cloudfront-waf" {
  name        = "cloudfront-waf"
  description = "Cloudfront rate based statement."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "rule-1"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 10000
        aggregate_key_type = "IP"

        scope_down_statement {
          geo_match_statement {
            country_codes = ["GE"]
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "rule-metric-name"
      sampled_requests_enabled   = false
    }
  }

  tags = {
    Tag1 = "Value1"
    Tag2 = "Value2"
  }

  visibility_config {
    cloudwatch_metrics_enabled = false
    metric_name                = "metric-name"
    sampled_requests_enabled   = false
  }
}
*/

