# Kubernetes Cluster Add-ons

## Purpose And Required Order

This directory installs the capabilities that kubeadm deliberately leaves out:
pod networking, dynamic local storage, and Kubernetes GPU integration.

Run these phases only after `ansible/cluster.yml` completes and `kubectl` targets
the intended cluster. The order is part of the design:

1. Calico makes pod networking functional and nodes Ready.
2. Local-path-provisioner creates cache PVCs on the worker.
3. GPU Operator advertises and validates the GPU.
4. vLLM can then schedule with both its PVC and GPU resource.

Skipping prerequisites usually produces Pending or NotReady objects rather than
a clear top-level error.

## Preflight: Prove Cluster Identity

Before any install, verify context and nodes:

```bash
kubectl config current-context
kubectl cluster-info
kubectl get nodes -o wide
```

Why: `kubectl` and Helm mutate whichever cluster the active kubeconfig targets.
A valid command against the wrong cluster is more dangerous than a failed command.

Expected before Calico: the API responds and both node names may appear, but one
or both nodes can remain NotReady because no CNI has initialized pod networking.

## Phase 1: Calico Pod Networking

### What Kubernetes Needs From A CNI

kubelet delegates pod network setup to a Container Network Interface plugin. The
CNI assigns pod addresses, creates interfaces and routes, and tears networking
down when pods disappear. Calico also provides Kubernetes NetworkPolicy
enforcement.

Without a CNI:

- normal pods cannot receive working pod networking;
- CoreDNS cannot become fully useful;
- nodes remain NotReady with a network-not-ready condition;
- later add-on pods cannot communicate reliably.

### Why The Tigera Operator

The operator watches Calico custom resources and reconciles the many underlying
DaemonSets, Deployments, RBAC objects, and configuration. Helm installs the
operator and desired Installation object; the operator manages Calico lifecycle.

### Why CRDs Are Installed First

CustomResourceDefinitions extend the Kubernetes API. The CRD chart is rendered
and applied server-side before the operator chart so the API recognizes Calico
resource kinds when Helm creates them.

### Install Calico 3.32.2

```bash
helm repo add projectcalico https://docs.tigera.io/calico/charts
helm repo update projectcalico
helm template calico-crds projectcalico/crd.projectcalico.org.v1 \
  --version v3.32.2 | kubectl apply --server-side -f -
helm upgrade --install calico projectcalico/tigera-operator \
  --version v3.32.2 \
  --namespace tigera-operator \
  --create-namespace \
  --values k8s/calico/values.yaml \
  --wait
```

`helm upgrade --install` is rerunnable: it installs when absent and calculates an
upgrade when present. `--wait` waits for chart-managed readiness, but always run
the explicit cluster checks below because operator readiness and network behavior
are not identical claims.

### Values Explained

| Setting | Value | Why |
| --- | --- | --- |
| `installation.enabled` | `true` | Creates the Calico Installation custom resource. |
| `controlPlaneReplicas` | `1` | Matches this one-control-plane lab and saves resources. |
| CNI type | `Calico` | Calico owns pod interface setup. |
| IPAM type | `Calico` | Calico allocates pod addresses. |
| BGP | `Disabled` | Avoids routed pod-prefix exchange in this simple Azure topology. |
| Pod pool | `192.168.0.0/16` | Must exactly align with kubeadm's pod subnet. |
| Encapsulation | `VXLAN` | Carries pod traffic over the Azure VNet without per-pod Azure routes. |
| NAT outgoing | `Enabled` | Source-NATs pod traffic leaving the cluster. |
| Node selector | `all()` | Every Kubernetes node participates in the pool. |
| Calico API server | Disabled | Not needed for baseline Kubernetes NetworkPolicy use. |
| Goldmane/Whisker | Disabled | Saves resources; observability UI is outside the current scope. |

Terraform enables Azure NIC forwarding, and Ansible enables Linux forwarding.
VXLAN still depends on NSGs and host networking permitting required node traffic.

### Verify Calico

```bash
kubectl wait --for=condition=Ready nodes --all --timeout=10m
kubectl get nodes -o wide
kubectl get pods --namespace calico-system -o wide
kubectl get pods --namespace kube-system -o wide
kubectl get installation.operator.tigera.io default -o yaml
```

Healthy evidence:

- both nodes report Ready;
- Calico node pods run on both nodes;
- operator-managed components are available;
- CoreDNS is Running;
- the Installation reports healthy conditions.

For deeper learning, run a temporary pod on each node and test pod-IP and Service
DNS connectivity. Node Ready alone does not prove every network path or policy.

### Calico Failure Guide

| Symptom | Investigate | Common Cause |
| --- | --- | --- |
| Nodes remain NotReady | Node conditions and Calico pod logs | CNI init failure or CIDR mismatch |
| Calico pods Pending | Events, taints, resource pressure | Scheduling constraint or insufficient resources |
| Cross-node traffic fails | Azure forwarding, Linux sysctl, NSG, VXLAN | One forwarding layer blocked |
| Internet egress fails | NAT setting, routes, Azure outbound path | Missing SNAT/default route |
| DNS fails but pod IP works | CoreDNS pods, Service route, resolv.conf | DNS-specific rather than CNI-wide issue |
| Helm rejects resource kind | CRD inventory | CRDs absent or not established yet |

### Production Differences

Production may use Azure CNI/AKS, a routed Calico design, or another CNI. It needs
capacity-tested replicas, NetworkPolicies, flow observability, upgrade testing,
explicit MTU design, egress control, and multi-zone failure analysis.

Official references:

- https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm
- https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-public-cloud/azure
- https://kubernetes.io/docs/concepts/cluster-administration/networking/

## Phase 2: Local Dynamic Storage

### Storage Concepts

A PersistentVolumeClaim is an application's request for storage. A StorageClass
describes how a provisioner satisfies that request. A PersistentVolume represents
the bound storage. The pod mounts the claim rather than a host path directly.

The local-path provisioner creates directories on a node and exposes them as PVs.
This is dynamic provisioning, but the bytes remain local to that node.

### Why Kustomize

The upstream versioned manifest contains all provisioner resources. Kustomize
reuses it and applies small project-specific patches instead of copying a large
manifest that would be difficult to compare with upstream.

Tradeoff: rendering depends on GitHub availability, and a release tag is less
immutable than a vendored file with a verified digest. Production supply-chain
controls should mirror or vendor reviewed artifacts.

### Project Patches

`k8s/storage/kustomization.yaml` changes the provisioner ConfigMap:

- Only node `kube-gpu-worker` can provision paths.
- Data lives under `/opt/local-path-provisioner`.
- Unlisted nodes have an empty path list, preventing accidental control-plane data.
- The helper pod uses pinned BusyBox `1.37.0` rather than a mutable implicit tag.
- The helper tolerates disk pressure because cleanup may be needed during pressure.
- System-node-critical priority reduces the chance infrastructure helpers are displaced.

The exact worker name is intentional but tightly coupled to inventory and kubelet
hostname. Rename the node only with coordinated storage changes.

### Render Before Apply

```bash
kubectl kustomize k8s/storage > /tmp/local-path-rendered.yaml
```

Inspect the rendered image, nodePathMap, StorageClass name, reclaim policy, and
`WaitForFirstConsumer` binding mode before applying:

```bash
kubectl apply --kustomize k8s/storage
kubectl --namespace local-path-storage rollout status deployment/local-path-provisioner
kubectl get storageclass local-path -o yaml
```

### Why `WaitForFirstConsumer`

The scheduler first considers the consuming pod's node constraints, then storage
binds where that pod can run. Immediate binding could create local storage on a
node that does not satisfy the pod's GPU selector.

### Smoke Test

```bash
kubectl apply --filename k8s/storage/smoke-test.yaml
kubectl wait --for=condition=Ready pod/local-path-smoke-test --timeout=2m
kubectl exec local-path-smoke-test -- grep -F storage-ready /data/status
kubectl get pvc,pv -o wide
kubectl delete --filename k8s/storage/smoke-test.yaml
```

What the test proves:

- the StorageClass can dynamically create a PV;
- scheduling follows `accelerator=nvidia-gpu`;
- the volume mounts into a non-root container;
- the container can write and read data;
- the claim/PV lifecycle can be cleaned up.

What it does not prove: performance, disk capacity under model load, recovery after
node loss, snapshots, backup, encryption policy, or multi-node attachment.

### Local Storage Failure Semantics

| Event | Cache Outcome |
| --- | --- |
| vLLM process restart | Cache remains |
| vLLM pod replacement on same worker | Cache remains through PVC |
| Worker reboot | Cache normally remains on OS disk |
| Worker VM deallocation/restart | Cache remains if OS disk remains intact |
| Worker OS disk loss or VM replacement | Cache is lost |
| Pod scheduled to another node | Volume cannot follow automatically |

This is acceptable because model and compile data are caches reproducible from
pinned sources. Do not store irreplaceable conversations, user data, audit logs,
or benchmark evidence on this volume.

### Production Differences

Use an Azure Disk CSI StorageClass for durable RWO volumes or an appropriate RWX
service when multiple nodes must share data. Define encryption, snapshots,
restore tests, expansion, quotas, topology, retention, and deletion policy.

Official reference: https://kubernetes.io/docs/concepts/storage/storage-classes/

## Phase 3: NVIDIA GPU Operator

### Responsibility Split

| Component | Owner | Reason |
| --- | --- | --- |
| Kernel driver | Ansible | Host/kernel lifecycle is explicit and verified before cluster workloads. |
| NVIDIA Container Toolkit | Ansible | containerd integration is a host responsibility. |
| Node Feature Discovery | GPU Operator | Labels hardware features in Kubernetes. |
| NVIDIA device plugin | GPU Operator | Advertises allocatable GPU resources to kubelet/scheduler. |
| GPU Feature Discovery | GPU Operator | Adds NVIDIA-specific node labels. |
| Validators | GPU Operator | Checks the integrated Kubernetes GPU stack. |
| DCGM exporter | GPU Operator | Exposes GPU telemetry to Prometheus. |

`driver.enabled=false` and `toolkit.enabled=false` prevent two controllers from
managing the same host components.

### CDI

Container Device Interface is enabled. The device plugin and container runtime
use CDI metadata to inject GPU devices and libraries. Validate the actual runtime
path rather than assuming host `nvidia-smi` proves container access.

### Why The Namespace Is Privileged

GPU management components access host devices, paths, and runtime integration.
The namespace is labeled for privileged Pod Security Admission as required by
NVIDIA. This broad permission is isolated to the operator namespace; ordinary
application namespaces should remain restricted.

### ServiceMonitor Installation Order

`ServiceMonitor` is a Prometheus Operator custom resource. On a fresh cluster,
install GPU Operator with `dcgmExporter.serviceMonitor.enabled=false`, install
kube-prometheus-stack so the CRD exists, then upgrade GPU Operator with the
repository's current values. The current values enable the monitor and label it
`release: monitoring` for explicit discovery.

### Install GPU Operator 26.7.1

```bash
kubectl create namespace gpu-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace gpu-operator \
  pod-security.kubernetes.io/enforce=privileged --overwrite
helm upgrade --install gpu-operator \
  oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator \
  --version v26.7.1 \
  --namespace gpu-operator \
  --values k8s/gpu-operator/values.yaml \
  --set dcgmExporter.serviceMonitor.enabled=false \
  --wait --timeout 15m
```

The one-time override is required on a fresh cluster because Prometheus Operator
has not created the ServiceMonitor CRD yet. `k8s/monitoring/README.md` upgrades
this release without the override after installing that CRD.

NVIDIA documents Cosign verification for the OCI chart. Production pipelines
should verify signatures before installation:
https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html

### Verify Operator Health

```bash
kubectl get pods --namespace gpu-operator -o wide
kubectl get clusterpolicy
kubectl describe clusterpolicy cluster-policy
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
```

Expected worker allocatable GPU is `1`. Operator pods should be Running or
Completed as appropriate, and ClusterPolicy should report Ready.

### CUDA Validation Pod

```bash
kubectl apply --filename k8s/gpu-operator/cuda-validation.yaml
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/cuda-validation --timeout=5m
kubectl logs pod/cuda-validation
kubectl describe pod cuda-validation
kubectl delete --filename k8s/gpu-operator/cuda-validation.yaml
```

The pod requests `nvidia.com/gpu: 1`; therefore success proves more than running
`nvidia-smi` over SSH. It proves scheduler resource allocation, container creation,
device injection, driver-library access, and a non-root process executing the
GPU utility. Expected logs identify one NVIDIA A10.

### GPU Failure Guide

| Symptom | Investigate | Likely Layer |
| --- | --- | --- |
| Host `nvidia-smi` fails | Driver, DKMS, kernel, reboot | Ansible/host |
| Host works, allocatable missing | Operator pods, device-plugin logs, NFD labels | Kubernetes integration |
| Pod remains Pending | Events and allocatable GPU | Scheduler/resource availability |
| Pod starts but `nvidia-smi` fails | CDI specs, containerd config, toolkit, driver compatibility | Runtime injection |
| ClusterPolicy not Ready | Operator status and validator logs | Operator reconciliation |
| Metrics absent later | DCGM pod, Service, ServiceMonitor labels/CRD | Observability integration |

### Production Differences

Production should choose one tested ownership model for drivers/toolkit, verify
signed artifacts, drain nodes for driver changes, monitor XID/ECC/temperature and
memory, define GPU taints/tolerations, test kernel upgrades, and maintain a full
driver-CUDA-PyTorch-vLLM compatibility matrix.

## Complete Add-on Gate

Do not deploy vLLM until all statements are true:

- Both nodes are Ready.
- Calico and CoreDNS pods are healthy.
- `local-path` exists and its smoke test passed.
- GPU Operator ClusterPolicy is Ready.
- Worker allocatable GPU equals one.
- CUDA validation pod succeeded.
- No unexpected Warning events remain.
