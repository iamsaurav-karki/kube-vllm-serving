# Production Readiness Gap Analysis

## Executive Assessment

This repository is a strong learning and portfolio lab, not a production-ready
service. Its main strengths are explicit automation boundaries, version pins,
cost gates, non-root workload configuration, repeatable static validation, and
layered runtime acceptance criteria.

Its intentional constraints are also production blockers: one control plane, one
Spot GPU node, one local disk, one model replica, direct node public IPs, local
Terraform state, no tested backup/restore, no public TLS path yet, no production
identity/rate limiting, and no measured SLO evidence.

## Lab Versus Production

| Concern | Current Lab | Production Direction |
| --- | --- | --- |
| Kubernetes control plane | One kubeadm node with stacked etcd | AKS or 3+ control planes across zones with stable API endpoint |
| GPU capacity | One Spot A10 | Multiple nodes, capacity strategy, regular fallback, autoscaling/queueing |
| Public networking | Static public IPs on both VMs | Private nodes/API, managed edge/load balancer, WAF, controlled egress |
| Pod networking | Calico VXLAN, broad internal NSG | Tested CNI/MTU, default-deny policies, flow logs, egress policy |
| Storage | Local OS-disk cache | Managed CSI storage or object cache, snapshots, backup, topology design |
| Terraform state | Local | Encrypted remote backend, locking, RBAC, audit, backup |
| Node management | Mutable Ansible configuration | Immutable images or controlled node pools and replacement automation |
| Secrets | Kubernetes Secrets created manually | External secret manager, KMS/etcd encryption, rotation and audit |
| Model availability | One replica, Recreate | Multiple replicas/GPUs, canary rollout, warm capacity, queue/load shedding |
| Authentication | One bearer key | OIDC/service identities, tenant policy, short-lived credentials, authorization |
| TLS and edge | Planned | Automated certificates, gateway HA, WAF, rate limits, request limits |
| Observability | DCGM exporter configured; stack planned | Metrics, logs, traces, SLOs, paging, retention, runbooks |
| Recovery | Recreate/redownload assumptions | Tested RTO/RPO, etcd/data restore, region/AZ strategy |
| Supply chain | Many versions pinned | Signatures, SBOMs, scanning, mirrored artifacts, admission policy |
| Delivery | Manual commands | CI/CD, policy gates, environment approvals, progressive deployment |

## Availability

### Current failure behavior

- Control-plane VM loss removes API and etcd availability.
- GPU-worker eviction removes all inference capacity and public ingress.
- Local disk loss removes the warm cache.
- Recreate updates cause intentional inference downtime.
- Azure Spot restart is manual and capacity is not guaranteed.

### Production requirements

- Define availability and latency SLOs first.
- Use multiple failure domains and enough GPU capacity for one-node loss.
- Keep control-plane availability independent from application nodes.
- Use health-checked traffic distribution and graceful draining.
- Design queue limits, timeouts, backpressure, and load shedding.
- Test node loss, GPU fault, gateway loss, storage loss, and dependency outage.

## Scalability

Horizontal scaling is not `replicaCount: 2` when only one GPU exists. Every
replica needs schedulable GPU capacity, compatible storage/cache access, model
download bandwidth, host memory, and gateway routing.

Production capacity planning should measure:

- prompt and generation tokens per second;
- time to first token and inter-token latency;
- concurrent request behavior;
- input/output token distribution;
- KV-cache utilization and eviction;
- GPU compute/memory utilization;
- CPU tokenization and host-memory use;
- cold/warm startup and model download time;
- error and timeout rates at saturation.

Autoscaling needs a useful signal such as queue depth, active sequences, or
latency, not only CPU. GPU node provisioning can take longer than an HTTP request
timeout, so scaling must combine warm capacity and admission/queue controls.

## Security

### Current positive controls

- Key-only SSH.
- Administrator `/32` for SSH and kube-apiserver.
- Separate NSGs per node role.
- Non-root vLLM process with dropped capabilities and seccomp.
- No ServiceAccount token in the vLLM pod.
- Internal-only vLLM Service.
- Secrets omitted from Git and entered interactively.

### Required production controls

- Private nodes and Kubernetes API.
- Central identity, MFA, just-in-time administration, and separate human/service roles.
- Default-deny NetworkPolicies and explicit namespace boundaries.
- External secret manager, rotation, encryption at rest, and secret-access audit.
- Gateway TLS, WAF, rate limiting, authentication, authorization, request limits,
  and denial-of-wallet controls.
- Kubernetes audit logs and centralized host/workload logs.
- Pod Security Admission for application namespaces and narrowly documented exceptions.
- Image signature/provenance enforcement, SBOMs, vulnerability scanning, and patch SLAs.
- Prompt/output privacy, retention, deletion, and acceptable-use controls.
- Model license, data governance, and safety review.

## Reliability And Recovery

Define RTO and RPO for separate state classes:

| State | Suggested Production Treatment |
| --- | --- |
| Infrastructure definitions | Git, reviewed CI/CD, remote Terraform state |
| Kubernetes control-plane state | Managed control plane or tested etcd snapshots |
| Model artifacts | Approved registry/object store mirror with immutable IDs |
| Compile/model cache | Rebuildable cache with measured recovery time |
| User/application data | Durable database/storage with backups and restore tests |
| Secrets | External manager with versioning and break-glass access |
| Telemetry/audit | Durable centralized retention and access policy |

Backups are not proven until restoration succeeds under time and version
constraints.

## Observability And SLOs

Production monitoring should cover:

- Node: availability, CPU, memory, disk space/inodes, filesystem latency, network.
- Kubernetes: scheduling failures, restarts, readiness, API latency, etcd health.
- GPU: utilization, memory, temperature, power, ECC, XID, throttling.
- vLLM: request rate, queue depth, latency, token throughput, cache usage, errors.
- Gateway: TLS, request/response size, status, latency, auth failure, rate limiting.
- Business: successful inference, tenant usage, cost per request/token, quality signals.

Example initial SLO discussion points, not adopted targets:

- Availability of authenticated inference.
- P95 time to first token for defined prompt/concurrency classes.
- P95 inter-token latency.
- Error-rate budget excluding valid client errors.
- Maximum recovery time after GPU-node loss.

Targets must be based on user needs and measured system behavior.

## Delivery And Change Management

A production pipeline should run:

1. Terraform formatting, validation, security policy, and saved-plan review.
2. Ansible syntax/lint and tests against disposable images.
3. Helm lint/template, schema validation, and policy checks.
4. Image/model provenance and vulnerability checks.
5. Integration tests on a staging GPU environment.
6. Performance regression tests with fixed workloads.
7. Manual approval for production infrastructure and expensive capacity changes.
8. Progressive model/runtime rollout with automatic rollback criteria.

Every change should identify blast radius, rollback, observability, data migration,
and cost impact.

## Production Decision Questions

Before adapting this project, answer:

1. What are the availability, latency, throughput, and recovery objectives?
2. Is self-managed Kubernetes justified over AKS?
3. Can requests tolerate Spot interruption, and what regular fallback exists?
4. Is the model cache disposable, and where does durable application data live?
5. How many models, versions, tenants, and regions must be served?
6. What are peak context length and concurrency distributions?
7. How are model access, licensing, safety, privacy, and retention governed?
8. What is the maximum acceptable cost per token/request and monthly budget?
9. Which team owns 24/7 incident response and upgrades?
10. How will disaster recovery be exercised and evidenced?

## Suggested Evolution Path

1. Complete this lab and capture runtime evidence.
2. Add gateway, TLS, NetworkPolicies, monitoring, and benchmark automation.
3. Move Terraform state and secrets to managed secure systems.
4. Replace direct public node access with private administration and managed edge.
5. Move durable data off local storage.
6. Introduce a second GPU failure domain and test failover/update behavior.
7. Define SLOs and alerts from measured baseline behavior.
8. Automate CI/CD and policy gates.
9. Decide whether the resulting operational burden supports kubeadm or favors AKS.
