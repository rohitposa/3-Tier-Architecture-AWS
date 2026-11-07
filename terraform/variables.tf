variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "three-tier-app"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "repo_url" {
  description = "Git repo cloned by the EC2 instances at boot"
  type        = string
  default     = "https://github.com/rohitposa/3-Tier-Architecture-AWS.git"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min" {
  type    = number
  default = 2
}

variable "asg_max" {
  type    = number
  default = 4
}

variable "asg_desired" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_name" {
  description = "Must match the database name used in database/database_setup.sql"
  type        = string
  default     = "messages_db"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "alert_email" {
  description = "Email that receives the AI-generated incident summaries"
  type        = string
}

variable "gemini_api_key" {
  description = "Gemini API key (stored in SSM Parameter Store as SecureString)"
  type        = string
  sensitive   = true
}

variable "gemini_model" {
  type    = string
  default = "gemini-2.5-flash"
}
