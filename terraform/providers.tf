provider "aws" {
  region = var.region

  # Applied to every resource that supports tagging, without repeating them.
  # Tags are how you answer "what is this and can I delete it?" at 2am, and
  # how cost is attributed back to this project in Cost Explorer.
  default_tags {
    tags = {
      Project     = var.project
      ManagedBy   = "terraform"
      Environment = "nonprod"
    }
  }
}
