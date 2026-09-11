variable "aws_region" {
  default = "us-east-1"
}

variable "app_name" {
  default = "demo-api"
}

# Database password used by the application.
variable "db_password" {
  default = "REDACTED_FAKE_PASSWORD"
}

variable "image_tag" {
  default = "latest"
}
