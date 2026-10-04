# ADR-0004: Use Node-Local Storage For The Model Cache

## Status

Accepted for reproducible cache data only.

## Date

2026-09-29

## Context

Model files and vLLM compile artifacts are large and make cold startup slow. The
lab has one GPU worker, and these artifacts can be recreated from immutable image
and model references. Adding managed storage increases cost and cloud-specific
complexity.

## Decision

Use local-path-provisioner on `kube-gpu-worker` and an 80 GiB ReadWriteOnce PVC
mounted at `/home/vllm/.cache`. Persist both Hugging Face and vLLM compile caches.

## Alternatives Considered

### `emptyDir`

Advantages: simplest and automatically cleaned with the pod.

Rejected because every pod replacement would redownload and recompile artifacts.

### Azure Disk CSI

Advantages: managed durable block storage and better VM replacement behavior.

Not selected for the cost-minimized first lab. It is the preferred direction for
production RWO data where durability and node replacement matter.

### Shared File Storage

Advantages: multiple replicas can share downloaded model files.

Not selected because there is one replica, and shared filesystem cost/performance
tradeoffs are unnecessary for the baseline.

### Bake Model Into The Container Image

Advantages: no runtime model download and one deployable artifact.

Rejected because the image becomes very large, model/image release cycles become
coupled, registry transfer cost grows, and licensing/distribution policy becomes
more complex.

## Consequences

- Pod restarts on the same worker can use a warm cache.
- Worker OS-disk loss removes the cache.
- The PVC cannot transparently move to another node.
- Hostname and scheduling are coupled to `kube-gpu-worker`.
- No durable user/application data may rely on this volume.
- Recovery is redownload and recompilation from pinned sources.

## Revisit When

Adding a second GPU node, requiring faster disaster recovery, serving multiple
models, or storing any non-reproducible data.

## Source

https://kubernetes.io/docs/concepts/storage/storage-classes/#local
