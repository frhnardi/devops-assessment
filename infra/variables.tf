variable "aws_region" {
  default = "us-east-1"
}

variable "app_name" {
  default = "demo-api"
}

# Set per deploy to an immutable tag (the git SHA). Never "latest", or the
# task definition stops changing when the image does and rollback has no
# earlier version to point at.
variable "image_tag" {
  type = string
}
