output "cache_endpoint" {
  description = "Redis endpoint address, passed to Lambdas that read/write the cache as an environment variable."
  value       = aws_elasticache_cluster.this.cache_nodes[0].address
}

output "cache_port" {
  description = "Redis port."
  value       = aws_elasticache_cluster.this.port
}

output "cache_security_group_id" {
  description = "Security group ID of the cache itself, in case another resource needs to be granted egress to it."
  value       = aws_security_group.cache.id
}
