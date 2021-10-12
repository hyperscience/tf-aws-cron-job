data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

// ECS Cluster definition
// -----------------------
// We either create a cluster or use a provided one, depending on the value of var.ecs_cluster_name

resource "aws_ecs_cluster" "this" {
  count = var.ecs_cluster_name == "" ? 1 : 0
  name  = var.task_name
}
data "aws_ecs_cluster" "existing" {
  count        = var.ecs_cluster_name != "" ? 1 : 0
  cluster_name = var.ecs_cluster_name
}
locals {
  ecs_cluster_arn = var.ecs_cluster_name != "" ? data.aws_ecs_cluster.existing[0].arn : aws_ecs_cluster.this[0].arn
}


// ECS Task definition
// -------------------
// We use a terraform map object and serialize to Json to allow end-users to pass their custom task definition
// parameters as a variable to the module.  We only specify the minimum values needed to run the task and configure
// Cloudwatch logging
data "aws_ecr_repository" "existing" {
  name = var.ecr_repo_name
}

locals {
  container_definitions = [
    merge({
      "name" : var.task_name,
      "image" : "${data.aws_ecr_repository.existing.repository_url}:${var.image_tag}",
      "cpu" : var.task_cpu / 1024,
      "memoryReservation" : var.task_memory,
      "essential" : true,
      "logConfiguration" : {
        "logDriver" : "awslogs",
        "options" : {
          "awslogs-region" : data.aws_region.current.name,
          "awslogs-group" : var.task_name,
          "awslogs-stream-prefix" : var.task_name,
          "awslogs-create-group" : "true"
        }
      }
    }, var.extra_container_defs)
  ]
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.task_name
  container_definitions    = jsonencode(local.container_definitions)
  task_role_arn            = var.task_role_arn
  execution_role_arn       = local.ecs_task_execution_role_arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
}

// Cloudwatch trigger
// ------------------
resource "aws_cloudwatch_event_rule" "event_rule" {
  name                = var.task_name
  schedule_expression = var.cloudwatch_schedule_expression
}

// Failure notification configuration (using Cloudwatch)
// -----------------------------------------------------
// We create an event rule that sends a message to an SNS Topic every time the task fails with a non-0 error code
// We also configure the

resource "aws_cloudwatch_event_target" "ecs_scheduled_task" {
  rule      = aws_cloudwatch_event_rule.event_rule.name
  target_id = var.task_name
  arn       = local.ecs_cluster_arn
  role_arn  = aws_iam_role.cloudwatch_role.arn

  ecs_target {
    launch_type         = "FARGATE"
    platform_version    = "LATEST"
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.this.arn
    network_configuration {
      subnets = var.subnet_ids
    }
  }
}

resource "aws_cloudwatch_event_rule" "task_failure" {
  name        = "${var.task_name}_task_failure"
  description = "Watch for ${var.task_name} tasks that exit with non zero exit codes"

  event_pattern = <<EOF
  {
    "source": [
      "aws.ecs"
    ],
    "detail-type": [
      "ECS Task State Change"
    ],
    "detail": {
      "lastStatus": [
        "STOPPED"
      ],
      "stoppedReason": [
        "Essential container in task exited"
      ],
      "containers": {
        "exitCode": [
          {"anything-but": 0}
        ]
      },
      "clusterArn": ["${local.ecs_cluster_arn}"],
      "taskDefinitionArn": ["${aws_ecs_task_definition.this.arn}"]
    }
  }
  EOF
}

resource "aws_sns_topic" "task_failure" {
  name = "${var.task_name}_task_failure"
}

resource "aws_cloudwatch_event_target" "sns_target" {
  rule  = aws_cloudwatch_event_rule.task_failure.name
  arn   = aws_sns_topic.task_failure.arn
  input = jsonencode({ "message" : "Task ${var.task_name} failed! Please check logs https://console.aws.amazon.com/cloudwatch/home#logsV2:log-groups/log-group/${var.task_name}" })
}

data "aws_iam_policy_document" "task_failure" {

  statement {
    actions   = ["SNS:Publish"]
    effect    = "Allow"
    resources = [aws_sns_topic.task_failure.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "task_failure" {
  arn    = aws_sns_topic.task_failure.arn
  policy = data.aws_iam_policy_document.task_failure.json
}

// IAM Resources
// -------------
// We create 2 IAM roles:
// 1. A Task Execution role used to run the ECS task and log output to cloudwatch.  This can be overridden by the user if they are using a
//    non-default ECSTaskExecutionRole.
// 2. A second role used by Cloudwatch to launch the ECS task when the timer is triggered
//
// Users can add a 3rd role if the ECS Task needs to access AWS resources.

// Task Execution Role
// Includes essential ecs access and cloudwatch logging permissions
data "aws_iam_policy_document" "task_execution_assume_role" {
  statement {
    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com"
      ]
    }
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
  }
}

data "aws_iam_policy_document" "task_execution_cloudwatch_access" {
  statement {
    effect = "Allow"
    actions = [
      "logs:PutRetentionPolicy",
      "logs:CreateLogGroup"
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.task_name}:*"]
  }
}

data "aws_iam_role" "task_execution_role" {
  count = var.ecs_task_execution_role_name != "" ? 1 : 0

  name = var.ecs_task_execution_role_name
}

locals {
  ecs_task_execution_role_arn  = var.ecs_task_execution_role_name != "" ? data.aws_iam_role.task_execution_role[0].arn : aws_iam_role.task_execution_role[0].arn
  ecs_task_execution_role_name = var.ecs_task_execution_role_name != "" ? data.aws_iam_role.task_execution_role[0].name : aws_iam_role.task_execution_role[0].name
}

resource "aws_iam_role" "task_execution_role" {
  count = var.ecs_task_execution_role_name == "" ? 1 : 0

  name               = "${var.task_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.task_execution_assume_role.json
}

//resource "aws_iam_policy" "task_execution_logging_policy" {
//  name   = "${var.task_name}-logging"
//  policy = data.aws_iam_policy_document.task_execution_cloudwatch_access.json
//}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  count = var.ecs_task_execution_role_name == "" ? 1 : 0

  role       = local.ecs_task_execution_role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_cloudwatch_access" {
  role       = local.ecs_task_execution_role_name
  policy_arn = aws_iam_policy.task_execution_logging_policy.arn
}

// Cloudwatch execution role
data "aws_iam_policy_document" "cloudwatch_assume_role" {
  statement {
    principals {
      type = "Service"
      identifiers = [
        "events.amazonaws.com",
        "ecs-tasks.amazonaws.com",
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "cloudwatch" {

  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [aws_ecs_task_definition.this.arn]
  }
  statement {
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = concat([
      local.ecs_task_execution_role_arn
    ], var.task_role_arn != null ? [var.task_role_arn] : [])
  }
}

resource "aws_iam_role" "cloudwatch_role" {
  name               = "${var.task_name}-cloudwatch-execution"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_assume_role.json

}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.cloudwatch_role.name
  policy_arn = aws_iam_policy.cloudwatch.arn
}

resource "aws_iam_policy" "cloudwatch" {
  name   = "${var.task_name}-cloudwatch-execution"
  policy = data.aws_iam_policy_document.cloudwatch.json
}
