output "azs" {
  description = "Availability Zones this deployment will span."
  value       = local.azs
}

output "az_ids" {
  description = "Stable AZ IDs behind those names. Same physical zone in every account."
  value       = slice(data.aws_availability_zones.available.zone_ids, 0, var.az_count)
}
