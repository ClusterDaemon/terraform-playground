output "eks_cluster_arn" {
  value = module.eks.eks_cluster_arn
}

output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_kubeconfig" {
  value = module.eks.kubeconfig
}

output "ecr_repositories" {
  value = aws_ecr_repository.eks_app[*].name
}

output "app_fqdn" {
  value = aws_route53_record.this[*].fqdn
}
