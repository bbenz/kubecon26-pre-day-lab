output "challenge_id" {
  description = "Challenge ID."
  value       = var.challenge_id
}

output "objects" {
  description = "Kubernetes objects applied for this challenge (kind/namespace/name)."
  value       = sort(keys(local.by_key))
}
