# End-To-End Implementation Guide

## How To Use This Guide

This document explains the sequence and reasoning. Component READMEs contain the
exact commands. Do not skip gates: each phase establishes an assumption required
by the next phase. A green static check proves configuration syntax, while a
runtime check proves behavior on real infrastructure.

No billable or destructive command should be run merely because it appears in a
guide. `terraform apply`, VM start, and `terraform destroy` require explicit
operator approval.

## Phase 0: Define Requirements And Constraints

### What this phase does

It converts a vague goal, "serve a model on Kubernetes," into testable system
requirements:

- Model: `Qwen/Qwen3-8B`, pinned to an immutable revision.
- Runtime: vLLM OpenAI-compatible server.
- Hardware: one 24 GB NVIDIA A10.
- Cluster: one regular control plane and one Spot GPU worker.
- Public endpoint: TLS at `llm.ksaurav.com.np`.
- Security: key-only SSH, constrained administration CIDR, API key, no committed secrets.
- Evidence: GPU test, authenticated completion, metrics, benchmark, and cost record.

### Why it matters

Infrastructure decisions are consequences of requirements. The model size drives
VRAM and disk needs; interruption tolerance permits Spot; one GPU constrains
replicas and rollout strategy; the learning objective favors kubeadm over AKS.

### Gate

Every requirement has a future verification command or artifact. Unknowns are
recorded as risks rather than silently assumed.

## Phase 1: Pin Versions And Estimate Cost

### What this phase does

`docs/versions.md` records the compatibility set. `docs/costs.md` records observed
public prices, excluded charges, quota pools, and idle-cost behavior.

### Why pinning matters

A tag such as `latest` can resolve to different bytes tomorrow. Reproducibility
requires pinning package versions, chart versions, workload images, and model
revisions. Pins do not guarantee compatibility; they make the tested combination
identifiable and upgrades intentional.

### Why quota comes before apply

Azure quota has regional, priority, and VM-family dimensions. A subscription can
have enough total vCPUs but zero quota for the selected family or Spot pool. The
initial quota was insufficient; the required Spot and Bsv2 quota was approved
before the 2026-09-30 deployment.

### Gate

- Version sources are recorded.
- Cost estimate states assumptions and exclusions.
- Required quotas are known.
- No resource creation occurs.

## Phase 2: Model Azure Infrastructure With Terraform

### What this phase does

Terraform declares 13 Azure resources: one resource group, one VNet, one subnet,
two NSGs, two static public IPs, two NICs, two NSG associations, and two VMs.

Terraform evaluates references to build a dependency graph. For example, a NIC
references the subnet and public IP, so those must exist first. Each VM explicitly
depends on its NSG association, preventing a public VM from starting before its
intended firewall policy is attached.

### Why plan before apply

`terraform plan` turns configuration and current provider state into a proposed
change set. Saving the plan ensures approval and apply refer to the same proposal.
Review focuses on resources, region, VM sizes, Spot mode, bid ceiling, disks,
public IPs, and NSG source ranges.

### What static validation proves

- `terraform fmt -check -recursive`: canonical formatting.
- `terraform init`: provider and module dependencies are available.
- `terraform validate`: references and provider schema are structurally valid.
- `terraform plan`: the provider accepts inputs and reports intended mutations.

None proves the VM can obtain quota, boot successfully, install packages, or run
the model.

### Gate

An operator reviews a fresh saved plan and current cost immediately before apply.
The approved plan was applied on 2026-09-30 and the runtime gates through the
vLLM phase passed. Future changes still require a fresh plan and approval.

## Phase 3: Provision Infrastructure

### What this phase will do

An explicitly approved `terraform apply tfplan` asks Azure to create the planned
resources. Terraform writes resource identities and attributes into state, then
outputs addresses and SSH commands used by Ansible.

### Why state matters

Terraform state maps configuration addresses such as
`azurerm_linux_virtual_machine.gpu_worker` to real Azure resource IDs. Losing
state does not delete resources, but makes safe change and destroy operations
harder. Local state is acceptable for this personal lab; production should use
an encrypted, access-controlled remote backend with locking and backup.

### Runtime verification

- Azure reports both VMs provisioned.
- The worker priority output is `Spot` or `Regular` as approved.
- SSH succeeds using the key and fails with password authentication.
- NICs have the expected static addresses and NSGs.
- No unreviewed source can reach SSH or kube-apiserver.

## Phase 4: Prepare Hosts With Ansible

### What `site.yml` does

The first play prepares both nodes:

1. Assert Ubuntu 22.04 to prevent applying assumptions to another OS.
2. Install repository and diagnostic prerequisites.
3. Disable swap because the default kubelet setup rejects active swap.
4. Load `overlay` for container filesystems and `br_netfilter` so bridged pod
   traffic can pass through netfilter.
5. Enable bridge filtering and IPv4 forwarding.
6. Install pinned containerd and switch it to the systemd cgroup driver.
7. Install and hold kubelet, kubeadm, and kubectl.

The second play prepares only the GPU worker:

1. Install kernel headers and DKMS prerequisites.
2. Install the checksum-verified NVIDIA repository keyring.
3. Install and hold the pinned driver.
4. Install and hold NVIDIA Container Toolkit.
5. Configure the NVIDIA runtime integration for containerd.
6. Reboot only when the driver changed.
7. Verify host GPU and toolkit visibility.

### Why run it twice

Configuration management should converge. The second run should report no host
configuration changes. This catches tasks that always mutate files, restart
services unnecessarily, or reinstall packages. The cluster role still creates a
fresh short-lived join token when run, so operational idempotency should be
interpreted carefully.

### Gate

All host checks pass, and a second `site.yml` run has no unexpected changes.

## Phase 5: Bootstrap Kubernetes

### What `cluster.yml` does

1. Render kubeadm `v1beta4` configuration on the control plane.
2. Run `kubeadm init` only when `/etc/kubernetes/admin.conf` is absent.
3. Copy the administrator kubeconfig with restrictive permissions.
4. Generate a hidden two-hour worker join token.
5. Run `kubeadm join` only when the worker lacks kubelet configuration.
6. Wait until the API sees the worker.
7. Apply worker and GPU scheduling labels.

### What kubeadm creates

kubeadm creates the cluster PKI, kubeconfigs, control-plane static pod manifests,
bootstrap tokens, and initial cluster configuration. It does not install a pod
network. Nodes commonly remain `NotReady` until Calico is installed.

### Sentinel-based idempotency

The playbook uses files as evidence of completed one-time operations:

- `/etc/kubernetes/admin.conf` means control-plane initialization occurred.
- `/etc/kubernetes/kubelet.conf` means a worker join occurred.

This prevents destructive repetition, but a stale file can hide a partially
broken cluster. Recovery must diagnose state before deleting sentinels or running
`kubeadm reset`.

### Gate

The API lists both nodes. Ready status is not required until the CNI phase.

## Phase 6: Install Pod Networking

### What this phase does

The Calico CRDs are installed first so the API recognizes Calico custom resources.
The Tigera Operator chart then reconciles the desired installation: Calico CNI,
Calico IPAM, VXLAN overlay, outgoing NAT, and one pod address pool matching the
kubeadm pod CIDR.

### Why CRDs come first

A CustomResourceDefinition teaches Kubernetes a new object type. Creating a
Calico Installation resource before its CRD exists fails because the API cannot
decode that kind.

### Why wait for Ready

Node Ready status proves kubelet, runtime, API communication, and CNI initialization
have converged enough for normal scheduling. It does not prove every pod-to-pod,
DNS, egress, or NetworkPolicy path; production validation should test those too.

### Gate

Both nodes are Ready, Calico pods are healthy, CoreDNS is Running, and test pods
can communicate as intended.

## Phase 7: Install And Validate Storage

### What this phase does

Kustomize fetches the tagged local-path-provisioner manifest and patches it so
volumes can be created only on `kube-gpu-worker`. A smoke-test PVC uses
`WaitForFirstConsumer`, allowing the consuming pod's node selection to drive
volume placement.

### Why local storage

Model weights and compile artifacts are large but reproducible. Keeping them on
the worker avoids a separate managed-disk service and speeds warm restarts. This
is a cache optimization, not a durability solution.

### Gate

The claim binds, the test pod writes and reads `storage-ready`, and cleanup
removes the test objects. Inspect the PV node affinity and host path when learning
how local volumes follow nodes.

## Phase 8: Enable Kubernetes GPU Scheduling

### What this phase does

GPU Operator deploys Node Feature Discovery, NVIDIA device integration, validators,
and DCGM exporter. It does not install the driver or toolkit because Ansible
already owns them. The namespace is privileged because hardware-management
components require host access.

### Validation layers

1. `nvidia-smi` on the host proves driver-to-GPU communication.
2. `nvidia-container-cli info` proves toolkit visibility.
3. Node allocatable `nvidia.com/gpu: 1` proves device-plugin registration.
4. The CUDA validation pod requests that resource and runs `nvidia-smi`, proving
   scheduler allocation and container device injection.

No single earlier check substitutes for the final pod test.

### Gate

ClusterPolicy is Ready, the node advertises one GPU, and the validation pod exits
Succeeded with A10 details.

## Phase 9: Deploy vLLM

### What the chart creates

- ServiceAccount without an automatically mounted API token.
- 80 GiB cache PVC.
- Internal ClusterIP Service on port 8000.
- One vLLM Deployment using one GPU.
- Optional ServiceMonitor when Prometheus CRDs exist.

### Why `Recreate`

The cluster has one GPU and one ReadWriteOnce local volume. A rolling update
would try to start the replacement before stopping the old pod, but the new pod
cannot obtain the occupied GPU or volume. `Recreate` accepts downtime and avoids
an update deadlock.

### Why three probe types

- Startup probe allows model download and engine initialization without liveness
  killing the container prematurely.
- Readiness controls whether the Service sends traffic.
- Liveness detects a process that became unhealthy after startup.

### Why persist both caches

`HF_HOME` stores downloaded model artifacts. `VLLM_CACHE_ROOT` stores compile
artifacts. Persisting both avoids repeated downloads and recompilation after pod
replacement on the same worker.

### Gate

The pod is Ready, `/health` succeeds, unauthenticated API access returns 401, an
authenticated completion returns valid JSON from the pinned model, and reasoning
output behaves as expected.

## Phase 10: Deploy The Public Edge And UI

Envoy Gateway is pinned to the GPU worker and exposes unprivileged proxy ports
through Kubernetes host-port mappings to public ports 80/443. cert-manager uses
Gateway API HTTP-01 routing to issue a Let's Encrypt certificate. Envoy redirects
HTTP to HTTPS, sends `/v1` to vLLM, and sends `/` to Open WebUI.

Open WebUI uses runtime-only administrator and vLLM API-key Secrets. Its 5 GiB
SQLite PVC is local to the worker. vLLM enables Qwen-compatible automatic tool
calling, and the served context is 8,192 tokens so the UI's system/tool prompt
still leaves room for generated output.

### Gate

Public DNS resolves to the worker, HTTP redirects, the certificate is Ready,
Open WebUI returns HTTP 200, unauthenticated `/v1/models` returns 401,
authenticated `/v1/models` returns 200, login succeeds, and UI inference returns
generated content.

## Phase 11: Install Observability

kube-prometheus-stack installs Prometheus Operator, Prometheus, Grafana,
kube-state-metrics, and node-exporter. GPU Operator and the vLLM chart create
explicitly labeled ServiceMonitors. Prometheus retains seven days or 15 GB on a
20 GiB local PVC; Grafana state uses a 5 GiB local PVC. A version-controlled
dashboard displays request rate, concurrency, latency percentiles, token rate,
KV-cache usage, GPU utilization, and framebuffer memory.

### Gate

All configured scrape targets are UP, vLLM and DCGM queries return real samples,
both PVCs are Bound, Grafana loads the custom dashboard, and inference traffic
populates the relevant panels.

## Remaining Phases

Benchmarks, CI, and cleanup automation remain. Each future phase should follow
the same pattern:

1. State the requirement and owner.
2. Pin and source the dependency.
3. Render and statically validate configuration.
4. Apply only after prerequisite gates pass.
5. Capture runtime evidence.
6. Document failure modes and rollback.
7. Compare the lab choice with the production design.

## Reusable Engineering Lessons

- Separate provisioning, host configuration, cluster bootstrap, and workloads.
- Make every phase produce evidence consumed by the next phase.
- Pin artifacts, but test the whole compatibility set.
- Treat caches differently from durable data.
- Understand which controller reconciles each object.
- Design updates around scarce resources such as a single GPU.
- A health check is only evidence for the layer it tests.
- Cost, quota, security, recovery, and observability are architecture concerns,
  not tasks to add after the application works.
