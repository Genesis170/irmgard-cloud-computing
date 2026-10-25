# Report: Cloud Computing Project
 
This report documents the setup, experiments and findings for the three
task areas: message queue (RabbitMQ), image processing web service with
relational database, and logging (Fluentd + OpenSearch). All experiments
were run on Minikube in the namespace `k8s-training`.

---
 
## 1. Message Queue with RabbitMQ
 
### 1.1 Minimum: single replica
 
RabbitMQ was first deployed as a StatefulSet with one replica, a
persistent volume claim, a headless service and a normal client service.
Credentials come from a Kubernetes Secret, hostnames and ports from a
shared ConfigMap. The webserver publishes one message per uploaded image;
the worker consumes it.
 
### 1.2 Extra: three replicas with redundancy
 
**Why `replicas: 3` alone is not enough:** Scaling the StatefulSet only
creates three independent brokers. They form a cluster only if they can
find each other, share an Erlang cookie, and are configured for peer
discovery. Even in a cluster, a *classic* queue lives on exactly one
node, so losing that node loses its messages.
 
**Solution (no operator, built by hand):**
 
| Concern | Solution |
|---|---|
| Node discovery | `rabbitmq_peer_discovery_k8s` plugin, using the Kubernetes API (ServiceAccount + Role + RoleBinding with read access to pods/endpoints) |
| Stable node names | StatefulSet plus **headless service** (`rabbitmq-headless`) gives each pod a DNS name such as `rabbitmq-0.rabbitmq-headless.k8s-training.svc.cluster.local` |
| Cluster authentication | Shared Erlang cookie, injected as environment variable from a Secret |
| Message redundancy | **Quorum queues** (`x-queue-type: quorum`, durable), replicated via Raft across all members |
| Client access | Separate ClusterIP service `rabbitmq-service` |
| Health | Readiness (`check_port_connectivity`) and liveness (`status`) probes |
 
The queue type is set by the client at declaration time, so both the
webserver (Go) and the worker (Ruby) declare the queue identically. A
mismatch causes `PRECONDITION_FAILED`.
 
### 1.3 Impact of losing a RabbitMQ pod
 
Experiments with a 3-member quorum queue:
 
| Scenario | Observed behaviour |
|---|---|
| Delete one pod (follower) | Cluster stayed available. A leader re-election was sometimes observed even though only a follower was removed (Raft term/heartbeat effects). No messages lost. |
| Delete leader | Automatic leader election among remaining members, queue available again after a short interval. |
| Delete two pods in quick succession | Queue was reachable again shortly after, because StatefulSet recreated the first pod before the second was removed, so a majority was effectively kept. |
| Scale to 1 replica (2 of 3 members gone) | `rabbitmqctl list_queues` ran into timeouts: no majority, queue blocked. After scaling back to 3 the queue was available again with all messages. |
 
**Conclusion.** A quorum queue with *n* members tolerates
⌊(n−1)/2⌋ simultaneous failures: 1 for n=3, 2 for n=5. Below a majority
the queue is *unavailable but not lost*. This is the CAP trade-off:
consistency is preferred over availability during a partition.
 
Further observations:
 
- **Queue membership is not tied to cluster size.** A queue declared when
  the cluster had 3 nodes keeps 3 members; new nodes only join it via
  `rabbitmqctl add_member`. A queue declared while 5 nodes exist gets 5
  members.
- **Reaching a state that works with 1 node.** Shrinking the cluster
  without shrinking queue membership leaves the queue blocked. A new
  queue declared against a single-node cluster gets one member.
**Operational finding: race condition during cluster bootstrap.** When
all three pods start cold at the same time, nodes occasionally failed
with `inconsistent_cluster` or looped on "Waiting for Mnesia tables".
The cause is a node trying to join while another is still merging its
Mnesia schema. Restarting the affected pod (and, after a partial reset,
deleting *all* PVCs, not just one) fixed it. This is one argument for
using the RabbitMQ Cluster Operator in production.

### 1.4 Does scaling out to 3 replicas increase throughput?
 
**TODO: measurements:** Suggested procedure, using the official
`perf-test` tool against both setups:
 
```bash
kubectl run perf-test --rm -it --restart=Never \
  --image=pivotalrabbitmq/perf-test -- \
  --uri amqp://<user>:<pass>@rabbitmq-service:5672 \
  --queue perf-quorum --queue-args x-queue-type=quorum \
  --producers 1 --consumers 1 --time 30
```
 
Run once against 1 node (classic queue, then quorum queue) and once
against 3 nodes (quorum queue), and record messages/s in a table.
 
**Expected reasoning:** A single quorum queue has one leader that handles all publishes, and every message must be acknowledged by a majority via Raft. Replication therefore adds overhead, and adding nodes does **not** raise the throughput of a single queue. Throughput can only scale by spreading load over *multiple* queues with leaders on different nodes. Redundancy costs performance; it
does not buy it.
 
### 1.5 Consumer-side scaling: prefetch
 
With several worker replicas, only one worker received messages. Without
a prefetch limit RabbitMQ pushes all ready messages to the first
connected consumer. Setting `channel.prefetch(1)` in the worker made
RabbitMQ hand out one unacknowledged message at a time, and the work
spread across all replicas. Scaling consumers needs correct consumer
configuration, not only more pods.
 
---

## 2. Image Processing Web Service and Relational Database
 
### 2.1 Horizontal scaling of the web service
 
The webserver is stateless and idempotent. It runs as a Deployment
behind a ClusterIP Service, so scaling means changing `replicas`.
 
**What happens:** `kube-proxy` distributes new connections across all
ready pods. A readiness probe on `/` keeps a new pod out of the service
until it answers.
 
**Pitfall:** Tests through `kubectl port-forward` showed all requests
hitting a single pod. `port-forward` binds to one pod when the tunnel is
opened and is not a load balancer. Testing from inside the cluster with a
curl pod against `irmgard-web-service:8080` showed the expected
distribution: 20 requests were split 11 / 9 between two pods.
 
### 2.2 Relational database
 
PostgreSQL is run by the **Zalando Postgres Operator** (Patroni-based):
 
- 3 instances: one primary, replicas via streaming replication (WAL)
- Two services created by the operator: `irmgard-postgres` (always the
  current primary) and `irmgard-postgres-repl` (replicas)
- Credentials generated by the operator, stored in Secrets per user
- `patronictl list` showed one leader and replicas in state `streaming`
  with lag 0; the cluster was also scaled to 4 instances through the
  custom resource
**Least privilege.** The application user `irmgard_app` is **not** the
database owner. A one-off Kubernetes `Job` (`irmgard-db-migration`)
connects as the privileged user, creates the table, and grants
`SELECT, INSERT, UPDATE` on it plus sequence usage to `irmgard_app`. The
webserver's own schema creation was removed from `main.go`.
 
### 2.3 Failure of the database pod
 
**TODO: run and record:** Suggested procedure:
 
```bash
kubectl exec -it irmgard-postgres-0 -- patronictl list    # find leader
# in a second terminal, send requests in a loop
kubectl delete pod <leader-pod>
kubectl exec -it <other-pod> -- patronictl list           # watch failover
```
 
Record: failover duration, HTTP status codes seen by clients during the
window, and whether data inserted before the failure is still present.
 
**Expected behaviour to verify.**
 
- With the single-instance StatefulSet version: DB requests fail until
  the pod restarts; data survives through the PVC; the web service
  process stays up, but `GET /` panics and `POST /` returns a database
  error.
- With the operator and 3 instances: Patroni promotes a replica;
  `irmgard-postgres` follows the new primary; outage limited to the
  seconds of promotion. Existing client connections drop and have to
  reconnect.
Effect on availability of the whole system: uploads and listing depend
on the database; image processing already in the queue can continue
because the worker does not talk to PostgreSQL.
 
---

