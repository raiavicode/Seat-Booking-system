############################################################
# MODULE: elasticache
#
# WHAT THIS IS:
#   A Redis cluster used as a fast, short-lived cache in front
#   of DynamoDB (Arrow 10: λ Process Payment -> ElastiCache).
#
# WHY IT'S HERE BUT *NOT* THE SOURCE OF TRUTH:
#   In an earlier version of this architecture, Redis held the
#   actual seat lock, and the Search Lambda checked Redis to
#   decide what to show as available. The bug: a lock written
#   to Redis wasn't guaranteed to be visible to every reader in
#   time, and Redis has no equivalent to DynamoDB's conditional
#   writes across a distributed set of callers -- two Lambdas
#   could both believe they'd won the lock. DynamoDB (see the
#   dynamodb module) is now the only place status is decided.
#   Redis's job shrank to what it's actually good at: caching
#   hot read data (e.g. seat map layouts, pricing) to take load
#   off DynamoDB, with a short TTL so a stale cache entry can
#   never live long enough to matter for correctness.
############################################################

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project_name}-cache-subnets-${var.environment}"
  subnet_ids = var.private_subnet_ids
}

# A security group that only allows inbound Redis traffic
# (port 6379) from the Lambda functions' own security group --
# nothing else in the VPC, and nothing from the public internet,
# can reach this cache directly.
resource "aws_security_group" "cache" {
  name        = "${var.project_name}-cache-sg-${var.environment}"
  description = "Allow Redis access only from the Lambda security group"
  vpc_id      = var.vpc_id

  # Ingress/egress rules are declared as separate aws_security_group_rule
  # resources below, rather than inline blocks here -- this security
  # group and the Lambda one in the root module need to reference EACH
  # OTHER (Lambda needs egress to this SG; this SG needs ingress from
  # Lambda's SG), and inline blocks referencing each other's IDs create
  # a circular dependency Terraform can't resolve. Separate rule
  # resources break the cycle since they depend on both SG IDs without
  # either SG's own resource body needing to reference the other.

  tags = var.tags
}

resource "aws_security_group_rule" "cache_ingress_from_lambda" {
  type                     = "ingress"
  description              = "Redis from Lambda functions"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cache.id
  source_security_group_id = var.lambda_security_group_id
}

resource "aws_elasticache_cluster" "this" {
  cluster_id = "${var.project_name}-cache-${var.environment}"
  engine     = "redis"

  # cache.t4g.micro is the cheapest current-generation node type
  # -- fine for a cache that's explicitly not load-bearing for
  # correctness. Size this up only if profiling shows it's a
  # throughput bottleneck, not because "cache" sounds important.
  node_type       = "cache.t4g.micro"
  engine_version  = "7.1"
  num_cache_nodes = 1
  port            = 6379

  subnet_group_name = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  # Daily automatic backups, retained for 3 days -- since this cache is
  # explicitly non-authoritative (see the module header comment), this
  # is a convenience for faster recovery after an accidental flush, not
  # a data-durability requirement the way it would be for DynamoDB.
  snapshot_retention_limit = 3
  snapshot_window          = "05:00-06:00"

  tags = merge(var.tags, {
    Component          = "data-layer"
    ArchitectureArrows = "10"
    Note               = "Cache only -- DynamoDB is the source of truth, not this."
  })
}
