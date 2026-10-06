# Documentation Guide

This repository is both an implementation and a study project. The documentation
is organized so you can learn the architecture before running commands, understand
why each tool owns a specific layer, and distinguish a cost-minimized lab from a
production platform.

## Recommended Reading Order

| Order | Document | What You Learn |
| ---: | --- | --- |
| 1 | [`architecture.md`](architecture.md) | Components, traffic paths, state, trust boundaries, and failure domains |
| 2 | [`implementation-guide.md`](implementation-guide.md) | The complete build sequence and the purpose of every phase |
| 3 | [`reproduction-guide.md`](reproduction-guide.md) | Exact ordered commands for rebuilding or adapting the project |
| 4 | [`../terraform/README.md`](../terraform/README.md) | Azure resources, Terraform dependency graph, inputs, plan review, and cost gates |
| 5 | [`../ansible/README.md`](../ansible/README.md) | Host preparation, kubeadm bootstrap, idempotency, and node verification |
| 6 | [`../k8s/README.md`](../k8s/README.md) | Calico, local storage, GPU Operator, and validation workloads |
| 7 | [`../helm/vllm/README.md`](../helm/vllm/README.md) | Model serving, secrets, GPU scheduling, probes, cache, and API tests |
| 8 | [`operations.md`](operations.md) | Routine checks, Spot recovery, upgrades, backups, and incident workflow |
| 9 | [`production-readiness.md`](production-readiness.md) | Gaps between this lab and a resilient production system |
| 10 | [`costs.md`](costs.md) | Price assumptions, quota pools, billing behavior, and cost controls |
| 11 | [`versions.md`](versions.md) | Version pins, compatibility responsibilities, and upgrade method |
| 12 | [`troubleshooting.md`](troubleshooting.md) | Evidence-first diagnosis and observed incidents |
| 13 | [`decisions/README.md`](decisions/README.md) | Architecture decisions, alternatives, and consequences |
| 14 | [`runtime-evidence.md`](runtime-evidence.md) | Dated proof from the deployed baseline |
| 15 | [`../Output-Verifications/README.md`](../Output-Verifications/README.md) | Indexed screenshots of infrastructure, workloads, inference, and observability |

## Documentation Status Language

The following words are used deliberately:

| Term | Meaning |
| --- | --- |
| **Implemented** | Configuration exists in this repository. It does not imply it ran successfully. |
| **Locally validated** | Static checks such as `terraform validate`, Ansible syntax checks, Helm rendering, or Kustomize rendering passed. |
| **Runtime verified** | A command was executed against provisioned infrastructure and produced the documented healthy result. |
| **Planned** | The design is recorded, but its manifests or automation do not exist yet. |
| **Production recommendation** | A stronger pattern to use for a real service; it may intentionally exceed this portfolio lab's scope. |

Current state: Terraform, Ansible, kubeadm, Calico, local storage, GPU scheduling,
CUDA execution, vLLM, public TLS/edge, Open WebUI, API authentication, and
Qwen3-8B inference and monitoring were runtime verified on 2026-09-30.

## How To Study Each Phase

For every layer, answer these questions before moving on:

1. What state does this layer own?
2. Which earlier layer must already be healthy?
3. What exact evidence proves this layer works?
4. What fails if the layer disappears?
5. Which values are immutable pins and which are environment-specific inputs?
6. Which secrets or privileged credentials does the layer handle?
7. How would the design change for multiple users, multiple GPUs, and a production SLO?

This method is reusable across cloud and Kubernetes projects. It prevents a
common mistake: treating a successful command as proof that the whole system is
correct.

## Source Policy

Design claims are grounded in source configuration and official documentation.
Important upstream references include:

- Kubernetes kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- Kubernetes container runtimes: https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- Calico on self-managed Azure: https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-public-cloud/azure
- NVIDIA GPU Operator: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html
- Kubernetes storage classes: https://kubernetes.io/docs/concepts/storage/storage-classes/
- vLLM containers: https://docs.vllm.ai/en/stable/deployment/docker.html
- Azure Spot VMs: https://learn.microsoft.com/en-us/azure/virtual-machines/spot-vms

Version-sensitive facts should be rechecked before upgrades. A URL documents the
upstream behavior; the repository pin records what this project intends to run.
