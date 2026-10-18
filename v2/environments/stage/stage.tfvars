enable_stateful_services = true
ai_postgres_image        = "pgvector/pgvector:pg17@sha256:ac08538c6f8b9904c33c8224c5e5706dbe760aca29db1d096972b4052c22a75d"
judge_postgres_image     = "postgres:16.2@sha256:4aea012537edfad80f98d870a36e6b90b4c09b27be7f4b4759d72db863baeebb"
judge_redis_image        = "redis:7.2.4@sha256:5a93f6b2e391b78e8bd3f9e7e1e1e06aeb5295043b4703fb88392835cec924a0"

enable_phase2_services = true
spring_image_digest    = "sha256:aa3dc994007771582d31984e9d0a316bc141afff2d5649f1c7164fc02579b201"
fastapi_image_digest   = "sha256:1592de4e12795360cfe99e276e01d8aaf384dc32e4b630152269ca794503f97b"
judge_image_digest     = "sha256:a20a509e6dad3585e5936b840d070968b4d0bd9f074f585e47415c88a3dc7a45"

enable_judge_worker_capacity = true
enable_judge_worker          = true
judge_worker_desired_count   = 1
enable_public_dns_cutover    = true
