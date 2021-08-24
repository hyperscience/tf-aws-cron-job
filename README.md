## Terraform: AWS Cron Job

Terraform Module that spins up a Docker-based scheduled job on AWS ECR.

Source code referenced by the blog post: https://hyperscience.com/tech-blog/running-scheduled-jobs-in-aws/

## Providers

| Name | Version |
|------|---------|
| aws | n/a |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| cloudwatch\_schedule\_expression | AWS cron schedule expression | `string` | n/a | yes |
| ecr\_repo\_name | Name of the ECR repo that contains the Docker image of your cron job | `string` | n/a | yes |
| ecs\_cluster\_name | (Optional) Name of the ECS Cluster that you want to execute your cron job. Defaults to your task name if no value is supplied | `string` | `""` | no |
| extra\_container\_defs | Additional configuration that you want to add to your task definition (see https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html for all options) | `map(any)` | `{}` | no |
| image\_tag | Docker tag of the container that you want to run | `string` | n/a | yes |
| subnet\_ids | Subnets where the job will be run | `list(string)` | n/a | yes |
| task\_cpu | CPU units to allocate to your job (vCPUs \* 1024) | `number` | `1024` | no |
| task\_memory | In MiB | `number` | `2048` | no |
| task\_name | Name of the task for resource naming | `string` | n/a | yes |
| task\_role\_arn | IAM role ARN for your task if it needs to access any AWS resources | `any` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| sns\_topic\_arn | ARN of the SNS Topic where job failure notifications are sent |
