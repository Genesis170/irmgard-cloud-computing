# Irmgard Cloud Computing

Kubernetes infrastructure for an image processing pipeline: manually
configured RabbitMQ cluster with quorum queues, highly available
PostgreSQL via the Zalando operator, MinIO object storage, and a
Fluentd/OpenSearch logging stack. Focus on redundancy, failover
behavior, and horizontal scaling, deployed and tested on Minikube.

## Architecture

TODO


## Components

| Component | Setup | Replicas | Notes |
|---|---|---|---|
| Webserver | Deployment | >= 1 | Go/Iris, image upload, publishes to RabbitMQ |
| Worker | Deployment | >= 1 | Ruby, YOLO object detection, consumes from RabbitMQ |
| RabbitMQ | StatefulSet (manual) | 3 | Quorum queues, peer discovery via k8s API |
| PostgreSQL | Zalando Postgres Operator | 3 | Streaming replication, automatic failover (Patroni) |
| MinIO | Deployment | 1 | S3-compatible object storage |
| Fluentd | DaemonSet | 1/node | Collects container logs |
| OpenSearch | Helm chart | 1 | Log storage and search |

## Attribution

The webserver (Go) and worker (Ruby) are based on template code provided
as part of the "Cloud Computing" course at HTW Saarland [2026]. My own
contributions cover:

- Completing the TODOs in both codebases (env-var configuration,
  bucket handling, queue declaration with quorum type, error handling,
  least-privilege user setup)
- The entire Kubernetes infrastructure (see `k8s/`): a hand-built
  RabbitMQ cluster (no operator, manual peer discovery/RBAC/health
  checks), HA PostgreSQL via the Zalando operator, MinIO, and a
  Fluentd + OpenSearch logging stack
- All debugging, redundancy testing, and failover analysis documented
  in `docs/report.md`

## Deployment order

```bash
# 1. Shared config & secrets
kubectl apply -f k8s/shared/

# 2. Backend services
kubectl apply -f k8s/rabbitmq/rabbitmq.yaml
kubectl apply -f k8s/postgres/postgres-cluster.yaml
kubectl apply -f k8s/minio/minio.yaml

# wait until all pods are Running/Ready
kubectl get pods -w

# 3. Application
kubectl apply -f k8s/webserver/irmgard-deployment.yaml
kubectl apply -f k8s/worker/worker-deployment.yaml

# 4. Logging (optional)
kubectl apply -f k8s/logging/fluentd-config.yaml
kubectl apply -f k8s/logging/fluentd-daemonset.yaml
```

**Note:** `k8s/shared/secret-htw.yaml` is not included in this repo.
Copy `secret-htw.example.yaml`, fill in your own credentials, and apply
it before anything else.

## Notable troubleshooting / things learned

- **RabbitMQ cluster bootstrap race conditions**: starting all 3 nodes
  simultaneously occasionally produced `inconsistent_cluster` errors
  during Mnesia schema merge — a known timing issue with manual peer
  discovery, resolved by restarting the affected pod(s).
- **Quorum queue majority behavior**: verified experimentally that a
  3-member quorum queue tolerates exactly 1 node failure; losing 2 of 3
  makes the queue unavailable (no data loss, but blocked) until a
  majority is restored — a direct illustration of the CAP theorem
  trade-off.
- **`kubectl port-forward` is not a load balancer**: it binds to a
  single pod for the lifetime of the forwarded connection, which
  initially made horizontal scaling of the webserver look ineffective.
  Verified real load-balancing behavior using an in-cluster client
  hitting the Service DNS name directly.
- **Image registry churn**: `minio/minio` and later `quay.io/minio/minio`
  became unavailable/unauthorized mid-project; had to migrate to
  `bitnami/minio`, then `bitnamilegacy/minio` as Bitnami restructured
  its Docker Hub namespace — a practical case for pinning specific,
  verified tags instead of `:latest` in reproducible setups.
- **Postgres least-privilege setup**: separated the Zalando-operator
  superuser (schema migration only) from the application's runtime
  user (`SELECT`/`INSERT`/`UPDATE` only), rather than giving the app
  owner-level rights.

## License

Course project — see attribution above regarding template code origin.