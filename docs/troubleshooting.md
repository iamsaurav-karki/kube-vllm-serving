# Troubleshooting Guide And Observed-Issue Log

This document separates reusable diagnostic procedure from incidents actually
observed in this project. Do not rewrite a plausible hypothesis as a historical
incident. Every incident entry must include evidence, root cause, resolution, and
a verification command.

## Evidence-First Method

1. Define the failing user operation and expected result.
2. Record UTC time, last known good time, environment, and exact versions.
3. Confirm Azure account, Terraform state, kubeconfig context, and namespace.
4. Identify the lowest layer capable of causing the symptom.
5. Gather status, events, logs, metrics, and recent configuration changes before restart.
6. Rank hypotheses and state which evidence would support or reject each.
7. Make the smallest reversible change.
8. Repeat the original failing operation and nearby health checks.
9. Record root cause; “restart fixed it” is a recovery action, not a root cause.

## Layer Map

| Layer | First Evidence |
| --- | --- |
| Azure allocation | Quota, SKU availability, VM power/provisioning state |
| Network/SSH | NSG rules, public/private IP, route, SSH verbose output |
| Host | systemd service state, journal, kernel modules/sysctls, disk |
| Kubernetes node | kubelet logs, node conditions, container runtime status |
| CNI/DNS | Calico pods/resources, CoreDNS, pod-to-pod/service tests |
| Storage | StorageClass, PVC/PV events, provisioner logs, node affinity |
| GPU | host `nvidia-smi`, runtime config, ClusterPolicy, device plugin, allocatable |
| vLLM | pod events, init/startup logs, VRAM, probes, model/cache/auth |
| Edge/TLS | DNS, certificate challenge, Gateway/route status, listener/backend |
| Monitoring | ServiceMonitor selectors, targets, scrape errors, metric names |

## Diagnostic Playbooks

These are future procedures, not claims that the failures occurred.

### Node Is Not Ready

```bash
kubectl describe node <node>
kubectl get events --all-namespaces --sort-by=.lastTimestamp
sudo systemctl status containerd kubelet --no-pager
sudo journalctl -u kubelet --since "30 minutes ago"
```

Check runtime availability, swap, cgroups, certificates, API reachability, CNI,
disk pressure, memory pressure, and clock. Fix the first failing dependency rather
than deleting application pods.

### Pod Is Pending

```bash
kubectl --namespace <namespace> describe pod <pod>
kubectl get nodes --show-labels
kubectl get pvc,pv --all-namespaces
```

Scheduler events usually state the unmet constraint: GPU, CPU/memory, selector,
taint/toleration, volume affinity, or unbound PVC. A second vLLM replica cannot
schedule with one GPU already allocated.

### PVC Is Pending

```bash
kubectl get storageclass
kubectl --namespace <namespace> describe pvc <claim>
kubectl --namespace local-path-storage logs deployment/local-path-provisioner
```

Confirm the default/explicit StorageClass, provisioner health, selected node,
filesystem permissions/capacity, and `WaitForFirstConsumer` scheduling events.

### GPU Is Not Allocatable

```bash
nvidia-smi
sudo ctr plugins list
kubectl get clusterpolicy
kubectl --namespace gpu-operator get pods -o wide
kubectl describe node kube-gpu-worker
```

Progress through host driver, container runtime integration, NFD labels, Operator
policy, device-plugin registration, then allocatable resource. Do not start with
the vLLM Deployment if the node advertises no GPU.

### vLLM Fails During Startup

```bash
kubectl --namespace llm-system describe pod -l app.kubernetes.io/name=vllm
kubectl --namespace llm-system logs deployment/vllm
kubectl --namespace llm-system get pvc,pv
```

Classify failure as image pull, secret/model authorization, DNS/egress, cache
permissions/capacity, CUDA compatibility, VRAM allocation, invalid arguments, or
probe timing. `OOMKilled` in pod status differs from CUDA out-of-memory in logs.

### API Returns 401 Or Cannot Connect

Check the Service endpoints and pod readiness before authentication. A 401 from
the correct server can prove reachability and rejected credentials; timeout or
connection refusal cannot. Never print the API key while debugging.

### Spot Worker Disappears

Use Azure instance view to distinguish eviction/deallocation from Kubernetes-only
failure. Follow `operations.md`; do not automatically replace Spot with regular
capacity because that changes cost and quota requirements.

## Observed Incidents

## Azure East Asia Quota Blocks Planned VMs

**Observed:** 2026-09-29

**Evidence:** `az vm list-usage --location eastasia` reported zero quota for the
NVADSA10v5 and Bsv2 families. Total regular regional quota was 14 vCPUs and total
low-priority quota was 3 vCPUs.

**Root cause:** The subscription does not yet have family or regional quota for
the planned 36-vCPU Spot GPU worker and 2-vCPU control plane.

**Resolution:** Request the quotas listed in `docs/costs.md` before applying the
Terraform plan.

**Verification:**

```bash
az vm list-usage --location eastasia --output table
```

Expected relevant limits are at least 36 low-priority vCPUs and 2 Bsv2-family
vCPUs. A pay-as-you-go fallback additionally requires 36 NVADSA10v5-family and
38 total regional vCPUs.

## Local Kubernetes Schema Validation Tried Cluster Discovery

**Observed:** 2026-09-29

**Evidence:** `kubectl apply --dry-run=client` attempted API discovery and failed
because there is no configured reachable cluster.

**Root cause:** Client dry-run can still require discovery information for the
resource types being submitted. This repository has not provisioned a cluster.

**Resolution:** Use deterministic offline render/lint checks before deployment,
and defer API-aware validation to a provisioned target or a pinned offline schema
validator.

**Verification:** Helm chart, Calico chart, GPU Operator chart, and Kustomize
resources render locally. Runtime/API validation remains explicitly unverified.

## Optional Linters Are Not Installed

**Observed:** 2026-09-29

**Evidence:** `kubeconform` returned `command not found`; `ansible-lint` was also
not available in the local toolchain.

**Root cause:** Those tools are not installed or pinned by this repository.

**Resolution:** Do not download arbitrary latest binaries during an evidence run.
Add pinned versions and checks through the planned CI/tool bootstrap work.

**Verification:** Existing required checks use installed tools. Optional lint and
offline Kubernetes-schema gates remain outstanding and must not be reported as passed.

## Generic NVIDIA Driver Package Had Mixed Dependencies

**Observed:** 2026-09-30

**Evidence:** Apt refused `nvidia-driver=595.91.07-1ubuntu1` because its exact
595-series dependencies conflicted with `xserver-xorg-video-nvidia`
`615.71.09-2ubuntu1`, selected from the same generic CUDA repository.

**Root cause:** The generic CUDA repository retained the old metapackage but its
unconstrained dependency resolution no longer produced a coherent 595 driver
stack. An exact top-level pin alone did not pin the entire dependency family.

**Resolution:** The Ubuntu server package was tested as an intermediate diagnostic
because it resolves a complete matched stack. Runtime verification then showed it
was not the correct driver class for Azure's NVadsA10 v5 vGPU. The final resolution
is the Microsoft-distributed Azure GRID driver documented in the next incident.

**Verification:** Apt simulation resolved all 595-server dependencies, proving the
original dependency problem. GPU initialization remained a separate failure.

**Prevention/Follow-up:** Validate exact package dependency resolution on a fresh
Ubuntu image, not only package presence in the repository.

## Data-Center Driver Rejected Azure A10 vGPU

**Observed:** 2026-09-30

**Evidence:** After the coherent 595 server stack installed and rebooted, DKMS
reported installed and Secure Boot was disabled, but `nvidia-smi` failed. Kernel
logs reported that PCI device `10de:2236` was unsupported by driver `595.91.07`.

**Root cause:** `Standard_NV36ads_A10_v5` exposes a licensed Azure GRID/vGPU
device. Microsoft documents the vGPU 18.8 GRID `570.237` branch for this family;
the generic NVIDIA data-center driver is the wrong driver class.

**Resolution:** Install Microsoft-distributed
`NVIDIA-Linux-x86_64-570.237-grid-azure.run`, verified by SHA-256, with DKMS and
remove the incompatible packaged driver.

**Verification:** Reboot, then require `nvidia-smi` and
`nvidia-container-cli info` to identify the Azure A10 successfully.

**Prevention/Follow-up:** Select drivers by cloud VM family and virtualization
model, not GPU marketing name alone. Recheck Microsoft's N-series table before
upgrading.

## Kubernetes Service Link Overrode vLLM Port

**Observed:** 2026-09-30

**Evidence:** The model downloaded, loaded on the GPU, and completed warmup, then
vLLM exited with `ValueError: VLLM_PORT 'tcp://...:8000' appears to be a URI`.
The pod environment also contained Kubernetes-generated `VLLM_PORT_*` variables.

**Root cause:** Kubernetes created legacy Service-link environment variables from
the Service named `vllm`. Its generated `VLLM_PORT` collided with vLLM's own
numeric environment setting namespace.

**Resolution:** Set `enableServiceLinks: false` in the pod specification. Service
DNS remains available and is the preferred discovery mechanism.

**Verification:** Roll out the corrected Deployment, require the pod to become
Ready, and verify authenticated inference.

**Prevention/Follow-up:** Disable service links for workloads whose environment
variable namespace can collide with Kubernetes Service names.

## Generated API Key Contained A Newline

**Observed:** 2026-09-30

**Evidence:** An authenticated in-pod request failed before transmission with
`ValueError: Invalid header value` and showed that the bearer value ended in
`\n`. The decoded Secret was 65 bytes rather than 64 hexadecimal bytes.

**Root cause:** Generator output had been stored with its terminating newline.
That byte became part of vLLM's configured API key, but newline characters are
invalid in an HTTP authorization header.

**Resolution:** Rotate the Secret using command substitution and
`--from-literal`, restart the Deployment, and keep the generated value out of
command output and source control.

**Verification:** The decoded value is 64 bytes, unauthenticated access returns
401, and an authenticated completion succeeds after the rollout.

**Prevention/Follow-up:** Document newline-free generation and avoid
`--from-file` for line-oriented generator output unless the file bytes are
validated first.

## cert-manager Installed Without Its CRDs

**Observed:** 2026-09-30

**Evidence:** The initial cert-manager Helm installation timed out and the API did
not recognize cert-manager resource kinds.

**Root cause:** Chart value `crds.enabled` defaults to `false`; installing the
controller alone did not install its CustomResourceDefinitions.

**Resolution:** Set `crds.enabled: true` in the pinned values, remove the
incomplete release, and reinstall chart `1.21.2`.

**Verification:** All cert-manager Deployments became Ready, the production
ClusterIssuer became Ready, and `llm-tls` was issued.

**Prevention/Follow-up:** Render the chart and verify CRDs are part of the planned
install before creating Issuer or Certificate objects.

## Open WebUI Had A Duplicate Ollama Environment Variable

**Observed:** 2026-09-30

**Evidence:** The first Open WebUI installation failed while rendering because
`ENABLE_OLLAMA_API` was defined by chart-native and custom values.

**Root cause:** A custom environment entry duplicated configuration already owned
by the chart's Ollama setting.

**Resolution:** Remove the duplicate variable and let the chart-native setting
own that behavior.

**Verification:** Helm revision 2 deployed successfully and the health endpoints
became Ready.

**Prevention/Follow-up:** Prefer chart-native values over duplicate `extraEnvVars`
and inspect rendered environment entries before installation.

## Envoy Could Not Bind Directly To Privileged Ports

**Observed:** 2026-09-30

**Evidence:** Envoy rejected its HTTP listener with `cannot bind '0.0.0.0:80':
Permission denied`. The process had `NET_BIND_SERVICE` only in its bounding set;
its permitted and effective sets were zero after startup.

**Root cause:** Envoy drops privileges before dynamically receiving listener
configuration, so adding a container capability did not leave an effective
capability at bind time.

**Resolution:** Keep Envoy non-root and capability-free. Listen on shifted
unprivileged ports 10080/10443 and map them with Kubernetes `hostPort` to worker
ports 80/443.

**Verification:** The proxy rollout completed, external HTTP reached Envoy, then
HTTP redirected and HTTPS routes succeeded.

**Prevention/Follow-up:** Prefer unprivileged listeners plus host-port mapping over
running the data plane as root or weakening `allowPrivilegeEscalation`.

## Open WebUI Automatic Tools Were Rejected

**Observed:** 2026-09-30

**Evidence:** UI and direct replay requests returned HTTP 400 with `"auto" tool
choice requires --enable-auto-tool-choice and --tool-call-parser to be set`.

**Root cause:** Open WebUI sent `tool_choice: "auto"`, while vLLM had only the
Qwen3 reasoning parser configured.

**Resolution:** Add `--enable-auto-tool-choice` and
`--tool-call-parser hermes` through the Helm chart.

**Verification:** The minimized tool-choice request returned HTTP 200, and a
simple request returned content with finish reason `stop`.

**Prevention/Follow-up:** Test the API shape produced by the actual UI, not only a
minimal client without tools.

## Open WebUI Prompt Exhausted The Served Context

**Observed:** 2026-09-30

**Evidence:** The UI reported a 4,096-token maximum, 4,097 input tokens, and zero
available output tokens for a short user message.

**Root cause:** Open WebUI's system prompt and tool schemas exceeded the
conservative 4,096-token vLLM serving limit before generation began.

**Resolution:** Increase `--max-model-len` to 8,192. The pinned model supports
40,960 positions, and vLLM reported a 30,736-token GPU KV cache after the change.

**Verification:** A request larger than 4,096 tokens returned HTTP 200; vLLM
reported maximum concurrency 3.75x at 8,192 tokens; normal UI-style inference
returned generated content.

**Prevention/Follow-up:** Size served context against the complete client-rendered
prompt, including system text and tool schemas, then validate KV-cache capacity
on the target GPU.

## Entry Template

### Short problem statement

**Observed:** YYYY-MM-DD

**Evidence:** Include the exact command and relevant output or event.

**Root cause:** Explain why the failure occurred, not only what changed.

**Resolution:** Describe the minimal corrective action.

**Verification:** Provide the command and expected healthy result.

**Prevention/Follow-up:** State the automation, alert, test, or documentation
change that reduces recurrence.
