output "agent_id" {
  description = "The ID of the Bedrock agent"
  value       = aws_bedrockagent_agent.main.agent_id
}

output "agent_alias_id" {
  description = "The ID of the agent alias"
  value       = aws_bedrockagent_agent_alias.main.agent_alias_id
}

output "knowledge_base_id" {
  description = "The ID of the knowledge base"
  value       = aws_bedrockagent_knowledge_base.main.id
}

output "aurora_cluster_arn" {
  description = "The ARN of the Aurora cluster"
  value       = aws_rds_cluster.aurora_vector_store.arn
}

output "s3_bucket_name" {
  description = "The name of the S3 bucket for knowledge base data"
  value       = aws_s3_bucket.knowledge_base_data.bucket
}

output "lambda_function_name" {
  description = "The name of the Lambda function for action groups"
  value       = aws_lambda_function.action_group_lambda.function_name
}
