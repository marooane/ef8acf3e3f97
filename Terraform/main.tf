# Provider configuration
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_caller_identity" "current" {}

data "aws_bedrock_foundation_model" "nova_lite" {
  model_id = "amazon.nova-lite-v1:0"
}

data "aws_bedrock_foundation_model" "titan_embed" {
  model_id = "amazon.titan-embed-text-v2:0"
}

# Random suffix for unique naming
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  suffix = random_id.suffix.hex
}

# S3 bucket for data sources
resource "aws_s3_bucket" "knowledge_base_data" {
  bucket = "${var.project_name}-kb-data-${local.suffix}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "knowledge_base_data" {
  bucket = aws_s3_bucket.knowledge_base_data.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Aurora Serverless v2 cluster for vector store
resource "aws_rds_cluster" "aurora_vector_store" {
  cluster_identifier     = "${var.project_name}-aurora-${local.suffix}"
  engine                = "aurora-postgresql"
  engine_mode           = "provisioned"
  engine_version        = "15"
  database_name         = "vectordb"
  master_username       = "postgres"
  manage_master_user_password = true
  enable_http_endpoint = true
  
  serverlessv2_scaling_configuration {
    max_capacity             = 1
    min_capacity             = 0
    seconds_until_auto_pause = 900
  }

  skip_final_snapshot = true
  
  tags = {
    Name = "${var.project_name}-aurora-cluster"
  }
}

resource "aws_rds_cluster_instance" "aurora_instance" {
  identifier         = "${var.project_name}-aurora-instance-${local.suffix}"
  cluster_identifier = aws_rds_cluster.aurora_vector_store.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora_vector_store.engine
  engine_version     = aws_rds_cluster.aurora_vector_store.engine_version
}

# IAM role for Bedrock agent
resource "aws_iam_role" "bedrock_agent_role" {
  name = "${var.project_name}-bedrock-agent-role-${local.suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
      }
    ]
  })
}

# IAM role policy for Bedrock agent
resource "aws_iam_role_policy" "bedrock_agent_policy" {
  name = "${var.project_name}-bedrock-agent-policy"
  role = aws_iam_role.bedrock_agent_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          data.aws_bedrock_foundation_model.nova_lite.model_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve"
        ]
        Resource = [
          aws_bedrockagent_knowledge_base.main.arn
        ]
      },
    ]
  })
}

# IAM role for Knowledge Base
resource "aws_iam_role" "bedrock_kb_role" {
  name = "${var.project_name}-bedrock-kb-role-${local.suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "bedrock_kb_policy" {
  name = "${var.project_name}-bedrock-kb-policy"
  role = aws_iam_role.bedrock_kb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = [
          data.aws_bedrock_foundation_model.titan_embed.model_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.knowledge_base_data.arn,
          "${aws_s3_bucket.knowledge_base_data.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
            "rds:DescribeDBClusters"
        ]
        Resource = aws_rds_cluster.aurora_vector_store.arn
      },
      {
        Effect = "Allow"
        Action = [
          "rds-data:BatchExecuteStatement",
          "rds-data:ExecuteStatement",
        ]
        Resource = aws_rds_cluster.aurora_vector_store.arn
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn
      }
    ]
  })
}

# Knowledge Base
resource "aws_bedrockagent_knowledge_base" "main" {
  name     = "${var.project_name}-kb-${local.suffix}"
  role_arn = aws_iam_role.bedrock_kb_role.arn
  
  knowledge_base_configuration {
    vector_knowledge_base_configuration {
      embedding_model_arn = data.aws_bedrock_foundation_model.titan_embed.model_arn
    }
    type = "VECTOR"
  }

  storage_configuration {
    type = "RDS"
    rds_configuration {
      credentials_secret_arn = aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn
      database_name         = aws_rds_cluster.aurora_vector_store.database_name
      resource_arn          = aws_rds_cluster.aurora_vector_store.arn
      table_name           = "bedrock_integration.bedrock_kb"
      
      field_mapping {
        metadata_field    = "metadata"
        primary_key_field = "id"
        text_field       = "chunks"
        vector_field     = "embedding"
      }
    }
  }

  depends_on = [
    aws_rds_cluster_instance.aurora_instance,
    terraform_data.setup_aurora_vector_db
  ]
}

# Data source for Knowledge Base
resource "aws_bedrockagent_data_source" "main" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  name             = "${var.project_name}-data-source-${local.suffix}"
  
  data_source_configuration {
    type = "S3"
    s3_configuration {
      bucket_arn = aws_s3_bucket.knowledge_base_data.arn
    }
  }
}

# Setup Aurora vector database
resource "terraform_data" "setup_aurora_vector_db" {
  depends_on = [aws_rds_cluster_instance.aurora_instance]

  provisioner "local-exec" {
    command = <<EOF
      # Wait for Aurora to be available
      aws rds wait db-cluster-available --db-cluster-identifier ${aws_rds_cluster.aurora_vector_store.cluster_identifier} --region ${var.aws_region}
      
      # Execute SQL to setup vector database
      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE EXTENSION IF NOT EXISTS vector;" \
        --region ${var.aws_region}
      
      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE SCHEMA IF NOT EXISTS bedrock_integration;" \
        --region ${var.aws_region}
      
      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE TABLE IF NOT EXISTS bedrock_integration.bedrock_kb (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          chunks TEXT,
          embedding VECTOR(1024),
          metadata JSON,
          custom_metadata JSONB
        );" \
        --region ${var.aws_region}
      
      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE INDEX ON bedrock_integration.bedrock_kb USING hnsw (embedding vector_cosine_ops) WITH (ef_construction=256);" \
        --region ${var.aws_region}
        
      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE INDEX ON bedrock_integration.bedrock_kb USING gin (to_tsvector('simple', chunks));" \
        --region ${var.aws_region}

      aws rds-data execute-statement \
        --resource-arn ${aws_rds_cluster.aurora_vector_store.arn} \
        --secret-arn ${aws_rds_cluster.aurora_vector_store.master_user_secret[0].secret_arn} \
        --database ${aws_rds_cluster.aurora_vector_store.database_name} \
        --sql "CREATE INDEX ON bedrock_integration.bedrock_kb USING gin (custom_metadata);" \
        --region ${var.aws_region}
EOF
  }
}

# Lambda function for action group
resource "aws_lambda_function" "action_group_lambda" {
  filename         = "action_group_lambda.zip"
  function_name    = "${var.project_name}-action-group-${local.suffix}"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "python3.11"
  timeout         = 30

  depends_on = [data.archive_file.lambda_zip]
}

# Create lambda deployment package
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "action_group_lambda.zip"
  source {
    content = <<EOF
def lambda_handler(event, context):
    """
    Simple supply chain function that returns a success message.
    This could represent various supply chain operations like:
    - Updating shipment status
    - Processing inventory updates
    - Logging supply chain events
    """
    
    # In a real scenario, this would contain
    # actual supply chain logic like updating databases,
    # processing orders, or tracking shipments
    
    return {
        'statusCode': 200,
        'body': 'Supply chain operation executed successfully',
        'operation': 'supply_chain_update'
    }
EOF
    filename = "index.py"
  }
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role-${local.suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Lambda permission for Bedrock
resource "aws_lambda_permission" "bedrock_invoke" {
  statement_id  = "AllowBedrockInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.action_group_lambda.function_name
  principal     = "bedrock.amazonaws.com"
  source_arn    = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:agent/*"
}

# Bedrock Agent
resource "aws_bedrockagent_agent" "main" {
  agent_name                  = "${var.project_name}-agent-${local.suffix}"
  agent_resource_role_arn     = aws_iam_role.bedrock_agent_role.arn
  description                 = "Bedrock agent for supply chain"
  foundation_model            = data.aws_bedrock_foundation_model.nova_lite.model_id
  idle_session_ttl_in_seconds = 1800
  
  instruction = <<EOF
You are a specialized AI Supply Chain Management Assistant. Your primary purpose is to provide immediate, accurate, and actionable support to supply chain professionals by serving as a centralized, intelligent repository for all documented processes, emergency protocols, and operational knowledge. Your goal is to enhance decision-making speed, ensure procedural compliance, and minimize disruption by delivering precise information contextually.
Accuracy & Citation: Always prioritize accuracy. When providing information, you must cite the specific source document, policy number, playbook section, or knowledge base article you are referencing. (e.g., "According to Section 4.2 of the Supplier Onboarding Policy POL-SC-004...").
Clarity & Conciseness: Deliver information in a clear, structured, and easily digestible format. Use bullet points, numbered steps, and headings where appropriate. Avoid unnecessary jargon unless it is standard industry terminology.
Proactive Guidance: Don't just answer the question asked. Anticipate follow-up needs. If a user asks about a procedure, also mention linked policies or common pitfalls. If they declare an incident, immediately guide them to the relevant playbook.
Action-Oriented: Your responses should empower the user to act. Phrase guidance as actionable steps. Use directives like "You should now...," "The next step is to...," or "Immediately notify..."
Confidentiality: You operate under the assumption that all information you handle is company-confidential. Do not speculate or provide information outside the provided knowledge base.
EOF

  # Note: prepare_agent is set to false initially to avoid Terraform issues
  # We'll prepare the agent using terraform_data resource
  prepare_agent = false
}

# Associate Knowledge Base with Agent
resource "aws_bedrockagent_agent_knowledge_base_association" "main" {
  agent_id         = aws_bedrockagent_agent.main.agent_id
  agent_version    = "DRAFT"
  knowledge_base_id = aws_bedrockagent_knowledge_base.main.id
  knowledge_base_state  = "ENABLED"
  description      = "Knowledge base association for company documents"

  depends_on = [terraform_data.prepare_agent]
}

# Prepare agent using terraform_data (workaround for Terraform provider limitation)
resource "terraform_data" "prepare_agent" {
  depends_on = [aws_bedrockagent_agent.main]
  
  triggers_replace = {
    agent_state = sha256(jsonencode(aws_bedrockagent_agent.main))
  }

  provisioner "local-exec" {
    command = "aws bedrock-agent prepare-agent --agent-id ${aws_bedrockagent_agent.main.agent_id} --region ${var.aws_region}"
  }
}

# Wait for agent preparation
resource "time_sleep" "prepare_agent_sleep" {
  create_duration = "30s"
  depends_on = [terraform_data.prepare_agent]

  lifecycle {
    replace_triggered_by = [terraform_data.prepare_agent]
  }
}

# Action Group
resource "aws_bedrockagent_agent_action_group" "main" {
  action_group_name = "demo-actions"
  agent_id         = aws_bedrockagent_agent.main.agent_id
  agent_version    = "DRAFT"
  description      = "Action group for supply chain functions"
  
  action_group_executor {
    lambda = aws_lambda_function.action_group_lambda.arn
  }
  function_schema {
    member_functions {
      functions {
        name        = "demo_function"
        description = "Demo function"
        parameters {
          map_block_key = "param1"
          type          = "string"
          description   = "The first parameter"
          required      = true
        }
      }
    }
  }

  depends_on = [
    aws_lambda_permission.bedrock_invoke,
    terraform_data.prepare_agent
  ]
}

# Agent Alias
resource "aws_bedrockagent_agent_alias" "main" {
  agent_alias_name = "${var.project_name}-agent-alias-${local.suffix}"
  agent_id         = aws_bedrockagent_agent.main.agent_id
  description      = "Production alias for the Bedrock agent"

  depends_on = [
    time_sleep.prepare_agent_sleep,
    aws_bedrockagent_agent_action_group.main,
    aws_bedrockagent_agent_knowledge_base_association.main
  ]
}

