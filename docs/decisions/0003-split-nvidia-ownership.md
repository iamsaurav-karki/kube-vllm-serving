# ADR-0003: Split NVIDIA Host And Kubernetes Ownership

## Status

Accepted for the portfolio lab.

## Date

2026-09-29

## Context

GPU workloads require a host kernel driver, container runtime integration,
Kubernetes hardware discovery, a device plugin, validation, and telemetry. GPU
Operator can manage the full stack, but this project also aims to teach and pin
host-level driver/toolkit installation explicitly.

Two controllers must not independently rewrite the same driver or containerd
configuration.

## Decision

Ansible installs and pins the NVIDIA driver and Container Toolkit, configures
containerd, reboots, and validates host visibility. GPU Operator installs Node
Feature Discovery, device integration, validators, and DCGM exporter with
`driver.enabled=false` and `toolkit.enabled=false`.

## Alternatives Considered

### GPU Operator Owns Everything

Advantages: unified lifecycle and less custom host automation.

Not selected because host driver/toolkit mechanics and version controls are a
learning objective. This may be preferable in production when the platform is
validated and node lifecycle is designed around the Operator.

### Manual Device Plugin Only

Advantages: fewer operator components.

Rejected because GPU Operator provides hardware discovery, validation, telemetry,
and a coherent supported integration path.

## Consequences

- Ownership is explicit and duplicate installation is prevented.
- Compatibility must be maintained across Ansible pins and Operator release.
- GPU Operator cannot repair a broken host driver/toolkit because they are disabled.
- Verification must cover host, runtime, device-plugin, pod, and model layers.
- Driver upgrades require coordinated node maintenance and Operator validation.

## Revisit When

Node images become immutable, GPU nodes scale automatically, or platform support
favors full Operator ownership.

## Source

https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html#pre-installed-nvidia-gpu-drivers-and-nvidia-container-toolkit
