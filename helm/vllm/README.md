# Qwen3-8B Serving With vLLM

## Purpose

This chart deploys one authenticated `Qwen/Qwen3-8B` vLLM server onto the A10
worker. It provides an internal OpenAI-compatible API and persists model and
compile caches. Public routing, TLS, and Open WebUI are later layers and are not
part of this chart.

## Prerequisites

Before installation:

- Both Kubernetes nodes are Ready.
- The `local-path` StorageClass passed its smoke test.
- `kube-gpu-worker` has label `accelerator=nvidia-gpu`.
- The node advertises allocatable `nvidia.com/gpu: 1`.
- The CUDA validation pod succeeded.
- The Hugging Face token and a strong vLLM API key are available to the operator.

Verify prerequisites:

```bash
kubectl get nodes --show-labels
kubectl get storageclass local-path
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
```

## Chart Contents

| Template | Kubernetes Object | Responsibility |
| --- | --- | --- |
| `serviceaccount.yaml` | ServiceAccount | Dedicated identity with no automatic API token |
| `pvc.yaml` | PersistentVolumeClaim | Model and compile cache |
| `service.yaml` | ClusterIP Service | Stable internal port and discovery name |
| `deployment.yaml` | Deployment | vLLM process, GPU request, probes, secrets, and cache mount |
| `servicemonitor.yaml` | Optional ServiceMonitor | Prometheus scraping of `/metrics` |
| `_helpers.tpl` | Helm helpers | Consistent names, labels, selectors, and digest image reference |

## Reproducibility

### Image Pin

The human-readable image tag is `v0.30.0`, while the workload renders an immutable
multi-architecture digest. Tags explain the release; the digest controls the
actual bytes pulled.

Why this matters: a mutable tag can point to different image content later, making
benchmark and incident results impossible to reproduce confidently.

### Model Pin

The model ID is `Qwen/Qwen3-8B`, and `--revision` uses commit
`b968826d9c46dd6066d109eabc6255188de91218`. Model repositories can change files,
tokenizers, or configuration under a branch name; the revision freezes the
requested snapshot.

Pins identify desired artifacts but do not independently prove supply-chain
trust. Production should scan images, verify signatures/provenance, mirror
critical artifacts, and control model licensing/approval.

## vLLM Settings Explained

| Setting | Value | Why | Tuning Risk |
| --- | --- | --- | --- |
| Model | `Qwen/Qwen3-8B` | Fits the target single A10 baseline | Different architectures may need trust or tokenizer options |
| Served name | Same as model ID | Gives clients a stable OpenAI model name | Changing it breaks clients |
| Revision | Commit SHA | Reproducible model files | New fixes require deliberate revision update |
| Dtype | `bfloat16` | Unquantized quality baseline supported by A10 | Uses more VRAM than quantized weights |
| Max model length | `8192` | Fits Open WebUI system/tool prompts with measured KV-cache headroom | Longer context reduces concurrency and can trigger OOM |
| GPU utilization | `0.90` | Leaves some VRAM outside vLLM's managed allocation | Too high risks OOM; too low reduces concurrency |
| Tensor parallel size | `1` | Exactly one allocated GPU | Must change with multi-GPU topology |
| Reasoning parser | `qwen3` | Separates Qwen3 reasoning from final content | Must remain compatible with model/runtime behavior |
| Tool parser | `hermes` with automatic choice | Accepts Open WebUI tool-aware requests | Parser and chat template must remain compatible |
| Host | `0.0.0.0` | Makes the server reachable through the pod network | Requires Service/API authentication controls |
| Port | `8000` | vLLM API and metrics endpoint | Must match probes and Service |

## Resource Model

The pod requests 8 CPU and 32 GiB memory, with limits of 32 CPU, 96 GiB memory,
and one GPU. Requests drive scheduling; limits constrain use. Extended GPU
resources are requested through limits and cannot be overcommitted like ordinary
CPU.

The large VM has enough host capacity, but resource settings still matter:

- Under-requesting permits contention and unpredictable initialization latency.
- Over-requesting can leave the pod Pending even when real workload use would fit.
- CPU throttling can reduce tokenization and request-processing throughput.
- Host RAM is used while loading weights and for runtime buffers.
- GPU VRAM holds weights, KV cache, kernels, and allocator overhead.

Production sizing must come from measured model startup, concurrency, context
length, and token-throughput tests rather than VM headline specifications.

## Scheduling

The node selector requires `accelerator=nvidia-gpu`, and the container requires
one `nvidia.com/gpu`. The label expresses intended placement; the extended
resource enforces actual device allocation.

No tolerations are configured. If the GPU node is tainted, the pod remains Pending
until values include a matching toleration. Production GPU nodes are commonly
tainted to prevent ordinary workloads consuming expensive capacity.

## Why One Replica And `Recreate`

There is one physical GPU and one ReadWriteOnce local PVC. A RollingUpdate would
normally create a replacement before removing the old pod. The replacement would
remain Pending because the old pod owns the only GPU and mounted local volume.

`Recreate` stops the old pod first, then starts the new one. This avoids rollout
deadlock but introduces downtime. Zero-downtime production updates require at
least another suitable GPU and a storage/cache strategy that supports placement
on it.

## Cache And Storage

The 80 GiB PVC mounts at `/home/vllm/.cache` and contains:

- `HF_HOME=/home/vllm/.cache/huggingface` for model artifacts.
- `VLLM_CACHE_ROOT=/home/vllm/.cache/vllm` for compile artifacts.

The official vLLM image supports non-root UID 2000 with GID 0 and group-writable
paths under `/home/vllm`. The chart follows that documented model with
`runAsUser: 2000`, `runAsGroup: 0`, and `fsGroup: 0`.

Official reference: https://docs.vllm.ai/en/stable/deployment/docker.html#run-as-a-non-root-user

Persisting both caches improves warm startup. Cache invalidation can occur when
model revision, vLLM/PyTorch/Triton versions, compilation settings, GPU architecture,
or cache contents change.

The local PVC does not protect against worker disk loss. This is acceptable only
because the contents are reproducible caches.

## Security Context

The pod and container use these controls:

- Non-root UID 2000.
- Runtime group and volume group 0 as required by the supported image pattern.
- RuntimeDefault seccomp profile.
- Privilege escalation disabled.
- All Linux capabilities dropped.
- Dedicated ServiceAccount.
- Automatic ServiceAccount token mounting disabled.
- Kubernetes Service-link environment injection disabled to prevent the `vllm`
  Service from creating a conflicting `VLLM_PORT=tcp://...` variable.
- Internal ClusterIP Service rather than public LoadBalancer.

GID 0 is broader than a dedicated application group. It is used because the
official image's non-root support relies on group 0 writable paths. Production
admission policies should document this exception.

The root filesystem is not read-only because vLLM and supporting libraries can
need writable runtime paths. A future hardening exercise should profile writes and
mount explicit `emptyDir` volumes before enabling read-only root filesystems.

## Health Probes

### Startup Probe

Checks `/health` every 10 seconds with 180 failures allowed, giving approximately
30 minutes for model download, compilation, and engine initialization. Until it
succeeds, Kubernetes does not run liveness/readiness failure logic against a slow
but progressing startup.

### Readiness Probe

Checks `/health` every 10 seconds. A failed readiness probe removes the pod from
Service endpoints without restarting it. This protects clients from receiving
traffic before the model is ready.

### Liveness Probe

Checks `/health` every 30 seconds after startup succeeds. Repeated failure causes
kubelet to restart the container. Liveness should detect unrecoverable process
health, not temporary load, or it can create restart loops during traffic spikes.

## Secrets

Two existing Kubernetes Secrets are referenced:

- `vllm-huggingface`, key `token`.
- `vllm-api-key`, key `api-key`.

The chart never creates or stores secret values. Create them interactively after
the namespace exists:

```bash
kubectl create namespace llm-system --dry-run=client -o yaml | kubectl apply -f -
printf 'Hugging Face token: ' >&2; read -rs HF_TOKEN; printf '\n' >&2
kubectl --namespace llm-system create secret generic vllm-huggingface \
  --from-literal=token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
unset HF_TOKEN
printf 'vLLM API key: ' >&2; read -rs VLLM_API_KEY; printf '\n' >&2
kubectl --namespace llm-system create secret generic vllm-api-key \
  --from-literal=api-key="${VLLM_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -
unset VLLM_API_KEY
```

For a generated key, use `VLLM_API_KEY="$(openssl rand -hex 32)"` with the same
`--from-literal` command. Do not pipe generator output into `--from-file`: a
trailing newline becomes part of the key and cannot be sent in an HTTP header.

Why use environment variables briefly: values do not appear as literal shell
history arguments. Why unset them: child processes and later shell inspection
should not retain them longer than needed.

Kubernetes Secrets are base64-encoded API objects, not automatically encrypted
application vaults. Production should enable etcd encryption at rest, restrict
RBAC, use an external secret manager/CSI integration, rotate keys, and audit access.

The API key is expanded into a vLLM process argument. A privileged process on the
node or inside the container could inspect process arguments. Treat node and pod
administration as privileged access.

## Static Validation

```bash
helm lint helm/vllm
helm template vllm helm/vllm --namespace llm-system > /tmp/vllm.yaml
helm template vllm helm/vllm --namespace llm-system \
  --set serviceMonitor.enabled=true > /tmp/vllm-with-monitoring.yaml
```

`helm lint` checks chart structure and templates. `helm template` proves values
render into YAML and lets reviewers inspect the exact digest, model revision,
resources, probes, selectors, and secret references.

These checks do not contact Kubernetes. Schema/CRD validation and runtime behavior
still require the target cluster or a pinned schema validator.

## Install

```bash
helm upgrade --install vllm helm/vllm \
  --namespace llm-system \
  --set serviceMonitor.enabled=false \
  --wait --timeout 35m
kubectl --namespace llm-system rollout status deployment/vllm --timeout=35m
```

Use the one-time override only when Prometheus Operator CRDs are absent. The
monitoring procedure later upgrades vLLM without the override and creates the
ServiceMonitor from the repository's current values.

The first startup downloads model files and can be much slower than a warm-cache
restart. The Helm timeout exceeds the startup-probe window to avoid the deployment
tool giving up before Kubernetes makes its final startup decision.

## Observe Startup

```bash
kubectl --namespace llm-system get pod,pvc,service -o wide
kubectl --namespace llm-system describe deployment vllm
kubectl --namespace llm-system describe pod -l app.kubernetes.io/name=vllm
kubectl --namespace llm-system logs deployment/vllm --follow
kubectl get events --namespace llm-system --sort-by=.lastTimestamp
```

Read events before logs when a pod is Pending: no container exists yet, so the
scheduler or volume controller usually explains the failure.

Read logs when a container is Running but not Ready: model download, CUDA,
memory, revision, or engine initialization errors are application/runtime issues.

## Internal API Verification

Start a temporary local tunnel:

```bash
kubectl --namespace llm-system port-forward service/vllm 8000:8000
```

### Health

```bash
curl --fail-with-body http://127.0.0.1:8000/health
```

This proves the port-forward, Service endpoints, pod listener, and vLLM health
handler. It does not run inference.

### Authentication Boundary

Call `/v1/models` without a key and expect HTTP 401:

```bash
curl --include http://127.0.0.1:8000/v1/models
```

### Authenticated Completion

```bash
printf 'vLLM API key: ' >&2; read -rs VLLM_API_KEY; printf '\n' >&2
curl --fail-with-body http://127.0.0.1:8000/v1/chat/completions \
  --header "Authorization: Bearer ${VLLM_API_KEY}" \
  --header 'Content-Type: application/json' \
  --data '{"model":"Qwen/Qwen3-8B","messages":[{"role":"user","content":"Return only: ready"}],"max_tokens":32}'
unset VLLM_API_KEY
```

Record response status, model field, finish reason, token counts, and output. Do
not publish API keys or sensitive prompts.

## ServiceMonitor

The ServiceMonitor selects the vLLM Service and scrapes `/metrics` every 15
seconds. On a fresh cluster, install vLLM with it disabled until Prometheus
Operator CRDs exist, then install monitoring and upgrade vLLM with the current
values. The `release: monitoring` label matches the explicit Prometheus selector.

## Failure Guide

| Pod State/Symptom | First Check | Likely Cause |
| --- | --- | --- |
| Pending, insufficient GPU | Pod events and node allocatable | GPU occupied or device plugin absent |
| Pending, unbound PVC | PVC/PV events, provisioner logs, node name | Storage unavailable or local-path mismatch |
| ImagePullBackOff | Image reference, registry reachability, events | Registry/network/digest issue |
| CreateContainerConfigError | Secret names and keys | Missing Secret or wrong key |
| CrashLoopBackOff | Current and previous logs | CLI argument, permissions, CUDA, or model error |
| Startup probe fails | Logs, network download, disk, GPU memory | Slow/failing model initialization |
| CUDA OOM | Logs and DCGM/`nvidia-smi` | Context, utilization, concurrency, or fragmentation |
| HTTP 401 with key | Secret value and Authorization format | Key mismatch or stale pod after rotation |
| Slow warm restart | PVC mount and cache directories | Cache miss, invalidation, or permissions |
| Service has no endpoints | Readiness and selectors | Pod not Ready or label mismatch |

## Updating Safely

1. Change one compatibility dimension at a time when possible.
2. Render the chart and review the exact diff.
3. Record new image digest and model revision.
4. Confirm driver/CUDA/PyTorch/vLLM/model compatibility.
5. Preserve benchmark conditions before comparing performance.
6. Expect downtime because strategy is Recreate.
7. Keep a known-good values/image/model combination for rollback.
8. Verify health, auth, inference, metrics, and GPU state after update.

Secret changes do not automatically change the Deployment pod template, so they
do not trigger a rollout. Rotate the Secret, then perform a controlled rollout
and verify both old and new credentials according to the rotation plan.

## Production Evolution

Production model serving should add multiple GPU nodes/replicas, a rollout and
cache strategy that supports them, TLS gateway, NetworkPolicies, tenant-aware
authentication and rate limits, external secret management, request/audit policy,
autoscaling or request queueing, disruption planning, model rollout/canary tests,
artifact provenance, durable telemetry, SLOs, alerts, and tested rollback.

For high concurrency or large models, evaluate tensor/pipeline parallel topology,
quantization, batching, KV-cache capacity, interconnect bandwidth, and failure
behavior through measured benchmarks rather than copying this single-GPU baseline.

## Official References

- vLLM Docker deployment: https://docs.vllm.ai/en/stable/deployment/docker.html
- vLLM reasoning outputs: https://docs.vllm.ai/en/stable/features/reasoning_outputs/
- vLLM engine arguments: https://docs.vllm.ai/en/stable/configuration/engine_args/
- Kubernetes probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes resource management: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes Secrets: https://kubernetes.io/docs/concepts/configuration/secret/
