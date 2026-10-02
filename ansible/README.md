# Node And Kubernetes Configuration With Ansible

## Purpose And Boundary

Ansible configures the operating systems after Terraform creates reachable VMs.
It installs and validates the container runtime, Kubernetes node packages, NVIDIA
host software, and kubeadm cluster bootstrap.

Ansible does not create Azure resources and does not install cluster add-ons such
as Calico, local-path-provisioner, or GPU Operator. Those are Kubernetes API
objects documented under `k8s/`.

## Why Two Playbooks

| Playbook | Responsibility | Safe Repetition Model |
| --- | --- | --- |
| `site.yml` | Convergent host preparation | Expected to report no changes on a healthy second run |
| `cluster.yml` | One-time kubeadm initialization/join and node labels | Uses sentinel files to avoid repeating destructive bootstrap operations |

Separating the phases makes failures observable. If host preparation fails, the
cluster has not been partially initialized. If kubeadm fails later, package and
runtime checks can be rerun independently.

## Directory Map

| Path | Purpose |
| --- | --- |
| `ansible.cfg` | Inventory path, role path, SSH safety, pipelining, timeout |
| `inventory/hosts.example.yml` | Non-secret topology and host-variable example |
| `group_vars/all.yml` | Shared version and network contract |
| `site.yml` | Host preparation orchestration |
| `cluster.yml` | Control-plane init, worker join, and labels |
| `roles/common/` | OS validation, swap, kernel, sysctl, and containerd |
| `roles/kubernetes/` | kubelet, kubeadm, and kubectl packages |
| `roles/nvidia/` | Driver, toolkit, containerd integration, reboot, checks |
| `roles/control_plane/` | kubeadm init and administrator kubeconfig |
| `roles/worker/` | kubeadm join |

## Inventory Model

The example inventory defines two groups:

- `control_plane`: one host named `kube-control`.
- `gpu_workers`: one host named `kube-gpu-worker`.

Group membership controls which roles run. Inventory hostnames also need to match
the node names registered by kubelet because `cluster.yml` waits for and labels
nodes by inventory name.

Create the real inventory only after an approved Terraform apply:

```bash
cp inventory/hosts.example.yml inventory/hosts.yml
chmod 600 inventory/hosts.yml
```

Replace both public-IP placeholders with Terraform outputs. Keep private addresses
aligned with the Terraform NIC configuration. The inventory references a private
SSH key path; it never embeds the key.

Before accepting a new SSH host key, compare the fingerprint with Azure boot
diagnostics, serial console, or another trusted path. `host_key_checking=True`
intentionally prevents silent trust of an unknown host.

## Shared Version And Network Contract

`group_vars/all.yml` couples these layers:

| Variable | Value | Consumer |
| --- | --- | --- |
| Kubernetes repository minor | `v1.36` | Apt repository URL |
| Kubernetes packages | `1.36.5-1.1` | kubelet, kubeadm, kubectl |
| Kubernetes cluster version | `v1.36.5` | kubeadm ClusterConfiguration |
| containerd | `2.3.6-1~ubuntu.22.04~jammy` | Common role |
| NVIDIA Azure GRID driver | `570.237` | NVIDIA role; required for NVadsA10 v5 vGPU |
| NVIDIA Container Toolkit | `1.20.1-1` | NVIDIA role |
| Pod CIDR | `192.168.0.0/16` | kubeadm and Calico |
| Service CIDR | `10.96.0.0/12` | kubeadm |
| API port | `6443` | kubeadm and Azure NSG |

Changing one value can require coordinated changes elsewhere. For example, a pod
CIDR change must update both kubeadm and Calico, and generally requires cluster
recreation or a supported migration rather than rerunning the template.

## `site.yml`: Host Preparation

### Play 1: All Kubernetes Nodes

The first play runs `common` and then `kubernetes` on every node with privilege
escalation.

### Common Role, Step By Step

#### 1. Verify Ubuntu 22.04

The role stops immediately unless facts report Ubuntu 22.04. Package names,
repository suites, kernel behavior, and NVIDIA compatibility are OS-specific.
Failing early is safer than partially modifying an unsupported node.

#### 2. Install prerequisites

`apt-transport-https`, CA certificates, curl, GPG, jq, and Python Debian tooling
support repository configuration and diagnostics. An apt cache validity period
avoids refreshing metadata on every task.

#### 3. Disable swap

Active swap is turned off and active swap entries in `/etc/fstab` are commented.
The default kubelet setup rejects swap-enabled nodes. Modern Kubernetes can be
configured for swap deliberately, but that requires an explicit kubelet policy;
this project chooses the simpler default.

Verification:

```bash
ansible all -i inventory/hosts.yml -a 'swapon --show'
```

Healthy output is empty.

#### 4. Load kernel modules

`overlay` supports layered container filesystems. `br_netfilter` allows bridged
traffic to traverse netfilter hooks used by Kubernetes networking. A template
under `/etc/modules-load.d/` persists both across reboot; `modprobe` activates
them immediately.

Verification:

```bash
ansible all -i inventory/hosts.yml -a 'lsmod'
```

Confirm both modules appear.

#### 5. Apply network sysctls

The sysctl template enables IPv4 forwarding and bridge packet processing for
IPv4 and IPv6. A handler runs `sysctl --system` only when the template changes.

Why a handler: configuration can be written declaratively, and the expensive or
disruptive apply action runs once after all notifying tasks.

Verification:

```bash
ansible all -i inventory/hosts.yml -a 'sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables'
```

Both values should be `1`.

#### 6. Install containerd

The role adds Docker's signed Jammy amd64 repository and installs exact
`containerd.io`. It generates containerd's default configuration and replaces
`SystemdCgroup=false` with `true`.

Kubelet and containerd must use compatible cgroup management. systemd is the
Linux service manager and cgroup owner on Ubuntu, so using it for both avoids two
cgroup managers creating inconsistent process hierarchies.

The package is held to prevent unattended drift beyond the tested version.
Holding also means security updates require an intentional compatibility review.

Risk: regenerating a default containerd config can overwrite local customizations.
Production roles should own a complete reviewed template or merge known settings
rather than deriving from live command output.

Verification:

```bash
ansible all -i inventory/hosts.yml -a 'containerd --version'
ansible all -i inventory/hosts.yml -a 'systemctl is-active containerd'
ansible all -i inventory/hosts.yml -a "grep 'SystemdCgroup = true' /etc/containerd/config.toml"
```

### Kubernetes Role, Step By Step

#### 1. Add the versioned package repository

The repository URL includes the Kubernetes minor version. This follows the
current per-minor package repository model and avoids accidentally crossing a
minor release.

#### 2. Install exact node packages

- `kubelet` is the node agent that runs pods and reports node status.
- `kubeadm` bootstraps and upgrades cluster control-plane/node configuration.
- `kubectl` is the administrative API client.

All three are held after installation. Kubernetes upgrades have version-skew and
ordering rules; automatic independent upgrades are unsafe.

#### 3. Enable kubelet

The service is enabled for boot. Before kubeadm writes configuration, kubelet may
restart or report errors; that is expected during bootstrap. kubeadm later supplies
the node-specific config and certificates.

Verification:

```bash
ansible all -i inventory/hosts.yml -a 'kubeadm version -o short'
ansible all -i inventory/hosts.yml -a 'kubelet --version'
ansible all -i inventory/hosts.yml -a 'apt-mark showhold'
```

### Play 2: NVIDIA GPU Workers

The second play targets only `gpu_workers`.

#### 1. Prepare for kernel modules

DKMS and headers matching the running kernel are installed. The NVIDIA driver
includes kernel modules, so a header mismatch or unsupported kernel causes build
failure.

#### 2. Trust the NVIDIA repository

The CUDA keyring package is downloaded with a fixed SHA-256 before installation.
The checksum proves downloaded bytes match the expected artifact. HTTPS alone
authenticates the server connection but does not freeze artifact contents.

#### 3. Install and hold the driver

The exact data-center driver is installed and held. Driver compatibility spans
the GPU, kernel, CUDA userland in containers, and vLLM/PyTorch stack. Treat it as
part of one compatibility matrix.

#### 4. Install NVIDIA Container Toolkit

The toolkit lets a container runtime inject GPU devices and required host driver
libraries. Installing a driver alone makes `nvidia-smi` work on the host but does
not make Kubernetes pods GPU-capable.

#### 5. Configure containerd integration

`nvidia-ctk runtime configure --runtime=containerd` creates NVIDIA's containerd
drop-in. The task is guarded by the drop-in path and notifies a containerd restart.

The existence guard is efficient but means future desired command changes will
not apply while that file exists. Production automation should validate content,
not just presence.

#### 6. Reboot conditionally

The worker reboots only when driver installation reports a change. The reboot
loads the kernel module and validates that the machine returns over SSH.

#### 7. Validate host GPU support

`nvidia-smi` proves host driver communication. `nvidia-container-cli info` proves
toolkit discovery. Kubernetes GPU allocation is tested later with GPU Operator
and a pod.

```bash
ansible gpu_workers -i inventory/hosts.yml -a 'nvidia-smi'
ansible gpu_workers -i inventory/hosts.yml -a 'nvidia-container-cli info'
```

## `cluster.yml`: kubeadm Bootstrap

### Control-Plane Role

#### Initialization sentinel

`/etc/kubernetes/admin.conf` is checked first. If it exists, `kubeadm init` is not
run again. Repeating initialization against an existing control plane could
damage cluster state.

#### Render kubeadm configuration

The root-only file declares:

- kubeadm API `v1beta4`.
- Private API advertise address and port 6443.
- containerd CRI socket.
- Exact Kubernetes version.
- Private stable control-plane endpoint.
- Pod and Service CIDRs.
- Certificate SANs for private IP and inventory hostname.

The public IP is intentionally absent from the SAN list. Use private routing or
an SSH tunnel for administration rather than weakening endpoint design.

#### Run `kubeadm init`

kubeadm creates PKI, kubeconfigs, etcd/control-plane static pod manifests, and
initial cluster objects. It does not install a CNI. A successful init can still
leave the node NotReady until Calico is installed.

#### Install administrator kubeconfig

The cluster-admin kubeconfig is copied to the Ansible user's home with directory
mode `0700` and file mode `0600`. This file grants broad cluster authority. Never
commit it, email it, or place it in ordinary artifact storage.

#### Generate a join token

A two-hour token is created for this playbook run. `no_log` protects the command
and token from Ansible output. The token is retained as an in-memory host fact for
the worker play.

Important idempotency detail: a token is generated on every `cluster.yml` run,
even when all workers are already joined. The task reports unchanged, but token
creation is still a cluster-side effect.

### Worker Role

`/etc/kubernetes/kubelet.conf` is the join sentinel. When absent, the worker runs
the generated join command with the explicit containerd socket. `no_log` prevents
token disclosure.

A stale kubelet file can suppress a needed rejoin after partial failure. Do not
delete it blindly. Inspect kubelet logs, node objects, certificates, and kubeadm
state before deciding whether a controlled `kubeadm reset` is necessary.

### Labeling

The final play waits for each inventory hostname to appear in the API, then adds:

- `node-role.kubernetes.io/worker=` for human-readable role identity.
- `accelerator=nvidia-gpu` for workload placement.

These labels do not prove a GPU exists. GPU Operator later advertises the actual
`nvidia.com/gpu` resource.

## Local Syntax Validation

These commands parse playbooks, inventory, roles, variables, and task/module
arguments without connecting to target nodes:

```bash
ansible-playbook -i inventory/hosts.example.yml site.yml --syntax-check
ansible-playbook -i inventory/hosts.example.yml cluster.yml --syntax-check
```

Syntax success does not prove package URLs, exact versions, remote permissions,
GPU compatibility, reboot recovery, or kubeadm runtime behavior.

## Execution Sequence After Approved Provisioning

```bash
ansible all -i inventory/hosts.yml -m ping
ansible-playbook -i inventory/hosts.yml site.yml --check --diff
ansible-playbook -i inventory/hosts.yml site.yml --diff
ansible-playbook -i inventory/hosts.yml site.yml --diff
ansible-playbook -i inventory/hosts.yml cluster.yml --diff
```

### Why check mode comes first

Check mode previews module changes where modules support it. Commands, package
repositories, hardware detection, and reboots cannot always be modeled perfectly,
so it is not a substitute for a reviewed real run.

### Why repeat `site.yml`

The second real run should show no unexpected host changes. Investigate any task
that repeatedly rewrites config or restarts services.

### Why `cluster.yml` comes last

The API server depends on containerd, kubelet, kernel settings, network addresses,
and stable hostnames. Bootstrap before those prerequisites converge creates harder
partial-failure recovery.

## Cluster Access Through SSH

The API endpoint is private. A local tunnel can map a workstation port to the
private API through the control-plane SSH host. Keep kubeconfig outside the
repository and adjust its server endpoint only in a protected local copy.

Do not weaken this by publishing cluster-admin kubeconfig or adding the public IP
to certificates without a deliberate threat-model review.

## Verification Matrix

| Layer | Command | Healthy Evidence |
| --- | --- | --- |
| SSH | `ansible all -m ping` | `pong` from both hosts |
| Swap | `swapon --show` | Empty output |
| Runtime | `containerd --version` | Pinned version |
| Kubernetes packages | `kubeadm version -o short` | `v1.36.5` |
| Driver | `nvidia-smi` | One NVIDIA A10, no driver error |
| Toolkit | `nvidia-container-cli info` | GPU/device/library details |
| API | `kubectl get nodes -o wide` | Both expected node names |
| Labels | `kubectl get nodes --show-labels` | Worker accelerator label |
| Static pods | `kubectl -n kube-system get pods` | Control-plane pods Running |

Node Ready status is expected only after Calico installation.

## Failure Diagnosis

| Symptom | Inspect First | Typical Causes |
| --- | --- | --- |
| SSH unavailable | Azure NSG, VM state, boot diagnostics, host key | Wrong IP/CIDR, failed boot, key mismatch |
| Apt version unavailable | Repository metadata and package policy | Pin removed, wrong suite, stale cache |
| containerd restart fails | `journalctl -u containerd`, config validation | Invalid generated/drop-in config |
| kubelet loops before init | `journalctl -u kubelet` | Expected missing bootstrap config or runtime mismatch |
| NVIDIA module fails | DKMS logs, kernel headers, Secure Boot | Header mismatch, unsupported kernel, module signing |
| Host GPU works but pod does not | Toolkit, CDI, device plugin, allocatable resource | Broken runtime integration or Operator config |
| kubeadm init fails | kubelet/containerd logs, ports, addresses | Swap, CRI, occupied ports, wrong private IP |
| Join fails | Token age, API reachability, CA hash, time sync | Expired token, NSG/routing, clock skew |
| Inventory node not found | `kubectl get nodes` names | kubelet hostname differs from inventory alias |

## Recovery Guardrails

- Do not run `kubeadm reset` as a generic troubleshooting step.
- Do not delete `/etc/kubernetes` or kubelet state before collecting evidence.
- Do not regenerate cluster PKI casually; certificate identity is cluster state.
- Do not unhold or upgrade one Kubernetes component independently.
- Do not rotate the NVIDIA driver during an active benchmark or loaded model.
- Preserve logs and exact command output in `docs/troubleshooting.md`.

## Production Evolution

A production kubeadm design needs multiple control-plane nodes, a stable API load
balancer, etcd backup/restore tests, certificate lifecycle management, controlled
minor upgrades, immutable node images, automated replacement, configuration drift
detection, centralized logs, hardened SSH access, separate admin identities, and
documented disaster recovery.

In many organizations, AKS is the better production choice because it transfers
control-plane availability and parts of node lifecycle to Azure. This project
uses kubeadm to teach the components, not to claim self-management is always best.

## Official References

- kubeadm cluster creation: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm configuration API: https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta4/
- Container runtimes and cgroups: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Kubernetes package installation: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
- NVIDIA GPU Operator preinstalled components: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#pre-installed-nvidia-gpu-drivers-and-nvidia-container-toolkit
