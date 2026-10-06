# Runtime Evidence

## Verified Baseline

The cost-minimized baseline was deployed in Azure East Asia and verified on
2026-09-30. Subscription identifiers, credentials, API keys, and Terraform state
are intentionally excluded from this document.

| Layer | Runtime evidence |
| --- | --- |
| Azure | The reviewed Terraform plan applied 13 resources successfully. |
| Configuration | A second Ansible host-configuration run reported no changes on either node. |
| Kubernetes | The control plane and GPU worker were Ready; Calico and CoreDNS were healthy. |
| Storage | The local-path smoke test wrote and read `storage-ready`; the vLLM 80 GiB PVC bound on the GPU worker. |
| GPU | The node advertised `nvidia.com/gpu=1`; a CUDA pod identified `NVIDIA A10-24Q`, driver `570.237`, and 24512 MiB memory. |
| Model | vLLM `0.30.0` loaded pinned `Qwen/Qwen3-8B` revision `b968826d9c46dd6066d109eabc6255188de91218`. |
| Authentication | An unauthenticated `/v1/models` request returned HTTP 401. |
| Inference | An authenticated chat request returned `deployment verified`, finish reason `stop`, and 21 total tokens. |
| Public edge | DNS resolved to the worker; HTTP redirected to HTTPS; Let's Encrypt issued `llm-tls`; Open WebUI returned HTTP 200. |
| Public API | Unauthenticated `/v1/models` returned 401 and authenticated access returned 200 through valid public TLS. |
| Open WebUI | Administrator login succeeded and a browser inference request reached Qwen3-8B. |
| Monitoring | Every configured Prometheus target reported UP, including vLLM and NVIDIA DCGM exporter. |
| Grafana | The sidecar loaded dashboard UID `qwen3-vllm-gpu`, titled `Qwen3 vLLM and GPU Overview`. |
| Community dashboards | Grafana contained `vLLM Metrics` from catalog `25263` revision 1 and `vLLM Monitoring - V2` from catalog `24756` revision 1. |
| Monitoring storage | Grafana's 5 GiB PVC and Prometheus's 20 GiB PVC were Bound through `local-path`. |
| Earlier shutdown | Both VMs reported `PowerState/deallocated` after the initial phase-7 checks; they were later restarted for edge/UI/monitoring work. |
| Final teardown | Terraform destroyed all 13 tracked Azure resources at `2026-09-30T12:25:16Z`; the resource group no longer exists. |

## Cost Window

The compute window ran approximately from `2026-09-30T07:44:35Z` to
`2026-09-30T09:58:45Z`, or 2.24 hours. At the documented public compute rate,
that is an estimated USD 2.31 before disks, public IPv4 addresses, transfer,
taxes, discounts, and Azure billing-data reconciliation. This estimate is not a
measured invoice amount.

## Inference Acceptance Response

Only non-sensitive response fields are retained:

```json
{
  "model": "Qwen/Qwen3-8B",
  "content": "deployment verified",
  "finish_reason": "stop",
  "usage": {
    "prompt_tokens": 18,
    "completion_tokens": 3,
    "total_tokens": 21
  }
}
```

## Edge And Monitoring Evidence

The indexed screenshot set in
[`Output-Verifications/README.md`](../Output-Verifications/README.md) provides
visual corroboration for the infrastructure, workload, inference, and monitoring
claims below. The screenshots are point-in-time evidence, not benchmark results.

The public path returned these status codes through a valid certificate:

```text
HTTP /                 301 -> https://llm.ksaurav.com.np/
HTTPS /                200
HTTPS /v1/models       401 without key
HTTPS /v1/models       200 with key
```

After a real inference request, representative Prometheus instant queries
returned:

```text
vllm:num_requests_running=0
vllm:request_success_total=31
vllm:e2e_request_latency_seconds_count=35
DCGM_FI_DEV_GPU_UTIL=99
DCGM_FI_DEV_FB_USED=21245
```

Counter values are point-in-time evidence, not benchmarks. The zero running value
is expected after the request completed.

Grafana API search also returned these dashboard identities:

```text
qwen3-vllm-gpu  Qwen3 vLLM and GPU Overview
ad9dcm5         vLLM Metrics
vllm-master-v2  vLLM Monitoring - V2
```

## Final Teardown Evidence

The explicitly approved saved destroy plan contained `0 add, 0 change, 13
destroy`. Applying that exact plan completed successfully:

```text
Apply complete! Resources: 0 added, 0 changed, 13 destroyed.
```

Post-destroy verification established:

```text
az group exists --name rg-kube-vllm-eastasia = false
terraform state list                         = empty
resources tagged project=kube-vllm-serving   = none
resources named kube-vllm                    = none
managed disks named kube-vllm                = none
public IPs named kube-vllm                   = none
```

DNS is externally managed and is not an Azure resource in this repository. Its A
record may continue pointing to the released worker address until changed or
removed by the DNS operator.

## Not Included In The Final Run

The planned benchmark matrix, a separate final Lens acceptance pass, and CI were
not completed before teardown. Functional, visual, and observability evidence is
recorded above. No project Azure compute, disks, public IPs, or resource group
remain after the final destroy.
