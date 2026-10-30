# Self-Managed Qwen3-8B Serving on Kubernetes

Portfolio-grade implementation and learning guide for deploying
`Qwen/Qwen3-8B` on a two-node, kubeadm-managed Kubernetes cluster in Azure. The
runtime-verified baseline covers infrastructure, host preparation, cluster add-ons,
GPU integration, a vLLM OpenAI-compatible API, Envoy Gateway, public TLS, Open
WebUI, Prometheus, Grafana, and NVIDIA DCGM metrics.

> [!WARNING]
> This repository is under construction. No Azure deployment should be run until
> `terraform plan` has been reviewed and the operator explicitly approves the
> estimated cost and resource creation.


## Cost Profile

The cost-minimized baseline uses a non-Spot `Standard_B2s_v2` control plane and
a Spot `Standard_NV36ads_A10_v5` worker. Spot makes this a lab and portfolio
deployment, not a high-availability production service: Azure can evict the GPU
worker at any time and replacement capacity is not guaranteed.

At public East Asia retail rates checked on 2026-09-29, estimated compute is
approximately USD 1.03/hour with a Spot GPU or USD 5.08/hour with a pay-as-you-go
GPU. Disks, public IPv4 addresses, and outbound data are additional. See
[`docs/costs.md`](docs/costs.md).

## Current Status

- [x] Architecture and version plan
- [x] Azure East Asia SKU and quota discovery
- [x] Terraform infrastructure applied from the reviewed 13-resource plan
- [x] Ansible node configuration executed twice and converged without changes
- [x] kubeadm, Calico, and local storage runtime verified
- [x] NVIDIA A10 host, scheduler, and CUDA-container paths runtime verified
- [x] Qwen3-8B vLLM deployment and authenticated inference runtime verified
- [x] Architecture, implementation, operations, and production-gap documentation
- [x] Envoy Gateway, TLS, and Open WebUI
- [x] Prometheus, Grafana, vLLM metrics, and DCGM dashboard
- [ ] Reproducible load-test results

## Safety Rules

- Secrets are created interactively and are never committed.
- Local Terraform state and `terraform.tfvars` are ignored.
- `terraform apply` and `terraform destroy` require explicit operator approval.
- The GPU VM should be deallocated whenever the benchmark environment is idle.
- Published benchmark tables must contain measured results, never estimates.

## Documentation

- [`docs/README.md`](docs/README.md): complete documentation map and status vocabulary
- [`docs/architecture.md`](docs/architecture.md): topology, dependencies, state, trust, and failure domains
- [`docs/implementation-guide.md`](docs/implementation-guide.md): end-to-end learning sequence and gates
- [`docs/reproduction-guide.md`](docs/reproduction-guide.md): canonical rebuild and adaptation procedure
- [`terraform/README.md`](terraform/README.md): Azure infrastructure and plan review
- [`ansible/README.md`](ansible/README.md): host preparation and kubeadm bootstrap
- [`k8s/README.md`](k8s/README.md): cluster networking, storage, and GPU integration
- [`helm/vllm/README.md`](helm/vllm/README.md): model-serving chart, security, and verification
- [`k8s/edge/README.md`](k8s/edge/README.md): direct host-port edge and certificate installation
- [`k8s/open-webui/README.md`](k8s/open-webui/README.md): UI secrets, deployment, and access
- [`k8s/monitoring/README.md`](k8s/monitoring/README.md): Prometheus, Grafana, targets, and dashboard access
- [`docs/operations.md`](docs/operations.md): routine checks, Spot recovery, upgrades, backups, and incidents
- [`docs/production-readiness.md`](docs/production-readiness.md): lab-to-production gap analysis
- [`docs/versions.md`](docs/versions.md): pinned components and rationale
- [`docs/costs.md`](docs/costs.md): cost assumptions and quota requirements
- [`docs/troubleshooting.md`](docs/troubleshooting.md): evidence-first diagnosis and observed incidents
- [`docs/runtime-evidence.md`](docs/runtime-evidence.md): dated deployment and acceptance evidence
- [`Output-Verifications/README.md`](Output-Verifications/README.md): indexed visual evidence from the deployed baseline
- [`docs/decisions/README.md`](docs/decisions/README.md): architectural decisions and alternatives
- [`tasks/plan.md`](tasks/plan.md): phased implementation and approval gates


# End-to-End Flow: Browser → Envoy Gateway → Open WebUI → vLLM → Qwen3-8B

Reflects the implemented repo (vLLM v0.30.0, Qwen3-8B, namespace `llm-system`).

---

## 1. Components and where they run

| Component | Runs on | Role |
|---|---|---|
| Browser | Client laptop | Renders UI over HTTPS |
| Envoy Gateway | Cluster | Public DNS/TLS entry point, routes to Open WebUI (and `/v1` to vLLM) |
| Open WebUI pod | Cluster (CPU) | UI, admin auth, chat history (SQLite on PVC), builds requests |
| vLLM Service (ClusterIP) | Cluster network | `vllm.llm-system.svc.cluster.local:8000` |
| vLLM pod | GPU worker node | API server, tokenizer, scheduler, engine |
| Qwen3-8B weights | GPU VRAM | The neural network math |
| Hugging Face cache PVC | GPU worker node | Persistent model cache |
| Hugging Face Hub | Internet | Only used when artifacts are missing/invalid |
| Prometheus / Grafana / DCGM exporter | Cluster | Metrics, dashboards, GPU telemetry |

---

## 2. Startup flow (model loading, once per pod start)

```
helm install (helm/vllm)
        │
        ▼
Kubernetes scheduler places the pod on the GPU worker
   - resources: nvidia.com/gpu: 1
   - nodeSelector: accelerator=nvidia-gpu
   - no tolerations currently
        │
        ▼
containerd pulls the image by immutable digest:
   docker.io/vllm/vllm-openai@sha256:8a69...
   (the v0.30.0 tag is documentation metadata; the helper prefers the digest)
NVIDIA Container Toolkit exposes the GPU into the container
        │
        ▼
Container starts vLLM with these effective arguments:
   --model Qwen/Qwen3-8B
   --served-model-name Qwen/Qwen3-8B
   --revision b968826...            (pinned model revision)
   --dtype bfloat16
   --max-model-len 8192
   --gpu-memory-utilization 0.90
   --tensor-parallel-size 1
   --reasoning-parser qwen3
   --enable-auto-tool-choice
   --tool-call-parser hermes
   --api-key <from Secret>
        │
        ▼
Hugging Face cache (PVC)
   ├─ cache present → read local files (warm restart still inspects the cache)
   └─ missing/invalidated → download from the Hub (HF_TOKEN is supplied,
                            though the public model may not strictly need it)
        │
        ▼
vLLM reads config.json → builds the Qwen3 architecture with its own code
        │
        ▼
Weights (~16 GB BF16) load from safetensors → GPU VRAM
        │
        ▼
Engine profiling, KV-cache allocation, CUDA graph capture
   (implementation details of the pinned vLLM/PyTorch version, not a fixed contract)
        │
        ▼
HTTP server listens on :8000
        │
        ▼
startupProbe passes → readinessProbe passes → Service gets a usable endpoint
```

Notes:
- The ClusterIP Service exists from the start, but has no ready endpoint until the startup and readiness probes succeed.
- Total GPU memory use is higher than the ~16 GB of weights because VRAM also holds the KV cache, kernels, CUDA graphs, and allocator overhead. The captured dashboard showed about 20 GiB framebuffer use for this configuration.
- After a successful load, request processing makes no calls to Hugging Face.

---

## 3. Chat request flow

```
Browser
   │  HTTPS, public DNS/TLS
   ▼
Envoy Gateway
   ▼
Open WebUI Service → Open WebUI pod
   - auth (admin account, signup disabled)
   - assembles messages (system + history + new message)
   │
   │  OpenAI-compatible request (internal, cluster DNS)
   │  POST http://vllm.llm-system.svc.cluster.local:8000/v1/chat/completions
   │  Authorization: Bearer <key>
   ▼
vLLM ClusterIP Service → ready vLLM pod
   ▼
vLLM API server
   1. API-key check
   2. Qwen chat template: messages → prompt string
   3. Tokenization: prompt → token IDs
   4. Request enters the scheduler queue
   ▼
vLLM scheduler (continuous batching)
   - joins the request to the running batch
   - allocates KV-cache pages
   ▼
GPU (weights already in VRAM)
   PREFILL: process all prompt tokens → first token
   DECODE:  one token per step, repeated until stop/limit
   ▼
Detokenize + parse
   - reasoning parser (qwen3) separates thinking text from the answer
   - tool-call parser (hermes) handles tool calls
   ▼
SSE stream (OpenAI-compatible) → Open WebUI backend
   ▼
Open WebUI updates the browser over its own frontend transport
   (WebSocket support is enabled in this project)
   ▼
Browser renders text as it arrives
   ▼
Open WebUI persists the finished chat to SQLite (PVC)
```

Alternate path: the public `/v1` route lets API clients go Client → Envoy → vLLM directly, bypassing Open WebUI.

---

## 4. How Open WebUI is wired to vLLM

Configured through Helm values (`k8s/open-webui/values.yaml`):

```yaml
enableOpenaiApi: true
openaiBaseApiUrl: http://vllm.llm-system.svc.cluster.local:8000/v1
openaiApiKeyExistingSecret: open-webui-vllm-api
```

- The API key lives in a separate namespace-scoped Secret (`open-webui-vllm-api`) with the same value as the vLLM key.
- Open WebUI calls `GET /v1/models` to discover `Qwen/Qwen3-8B` for the dropdown.
- Beyond the connection values, the deployment also configures: admin credentials, SQLite PVC, public URL, disabled signup, default model, health probes, and node placement.

---

## 5. Monitoring flow (parallel to requests)

```
Prometheus ServiceMonitor → vLLM /metrics every 15 seconds
DCGM exporter            → GPU telemetry (utilization, memory, temperature)
Grafana                  → dashboards on top of Prometheus
```

---

## 6. Summary

**Startup:**
Helm → scheduler → GPU worker → digest-pinned vLLM container → PVC/Hugging Face cache → pinned Qwen3-8B revision → weights and runtime state in GPU VRAM → startup probe → readiness probe → Service endpoint ready

**Chat:**
Browser → HTTPS Envoy Gateway → Open WebUI → OpenAI-compatible request to vLLM ClusterIP Service → API-key check → chat template → tokenization → scheduler → continuous batching → GPU prefill/decode → reasoning/tool parsing → SSE to Open WebUI → browser rendering → SQLite chat persistence

**Monitoring:**
Prometheus ServiceMonitor → vLLM `/metrics` (15s) · DCGM exporter → GPU telemetry · Grafana → dashboards
