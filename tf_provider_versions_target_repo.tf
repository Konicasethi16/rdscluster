terraform {
  required_version = ">= 0.12.31"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.51.0"
    }
    datadog = {
      source  = "datadog/datadog"
      version = "~> 3.0.0"
    }
    
    null = {
      source  = "hashicorp/null"
      version = ">= 3.1.0"
    }
  }
}