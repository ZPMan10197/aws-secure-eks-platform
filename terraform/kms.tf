resource "aws_kms_key" "eks_secrets" {
  description             = "Envelope encryption for EKS Secrets"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Name = "${var.project}-eks-secrets"
  }
}

resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.project}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}