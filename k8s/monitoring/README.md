# Monitoring

This directory deploys kube-prometheus-stack `91.8.2` for the lab. Prometheus,
Grafana, kube-state-metrics, and node-exporter collect cluster, host, vLLM, and
NVIDIA DCGM metrics. Grafana remains a private ClusterIP and is reached through
`kubectl port-forward`; it is not exposed through the public Gateway.

## Design

- Prometheus retains seven days or 15 GB in a 20 GiB local-path PVC.
- Grafana uses a 5 GiB local-path PVC.
- Stateful monitoring pods are pinned to `kube-gpu-worker`, where the lab's
  local-path provisioner creates storage.
- ServiceMonitors must carry `release: monitoring`; this avoids scraping
  unreviewed monitors accidentally.
- Alertmanager is disabled because this lab has no configured notification
  receiver. Prometheus rule evaluation and Grafana visualization still work.
- Control-manager, scheduler, etcd, and kube-proxy ServiceMonitors are disabled
  because the kubeadm components expose metrics on loopback in this baseline.

## Install

Create the runtime-only Grafana credential before installing:

```bash
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
GRAFANA_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
kubectl --namespace monitoring create secret generic monitoring-grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal="admin-password=${GRAFANA_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset GRAFANA_PASSWORD

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring \
  prometheus-community/kube-prometheus-stack \
  --version 91.8.2 \
  --namespace monitoring \
  --values k8s/monitoring/values.yaml \
  --wait --timeout 15m

kubectl apply -f k8s/monitoring/dashboard.yaml
helm upgrade gpu-operator \
  oci://nvcr.io/nvidia/cloud-native-charts/gpu-operator \
  --version v26.7.1 \
  --namespace gpu-operator \
  --values k8s/gpu-operator/values.yaml \
  --wait --timeout 15m
helm upgrade vllm ./helm/vllm \
  --namespace llm-system \
  --wait --timeout 30m
```

## Verify

```bash
kubectl --namespace monitoring get pods,pvc
kubectl get servicemonitor --all-namespaces
kubectl --namespace monitoring port-forward service/monitoring-grafana 3000:80
```

Open `http://127.0.0.1:3000`. Retrieve the generated password without storing it
in source control:

```bash
kubectl --namespace monitoring get secret monitoring-grafana-admin \
  --output 'jsonpath={.data.admin-password}' | base64 --decode; printf '\n'
```

The custom dashboard is **Qwen3 vLLM and GPU Overview**. Generate inference
traffic before evaluating rate, latency, token-throughput, and GPU panels.

## Community Dashboards

Two Grafana Labs community dashboards were imported through the Grafana UI on
2026-09-30 and verified in the live instance:

| Catalog ID | Revision | Grafana title | Local UID | Source |
| --- | ---: | --- | --- | --- |
| `25263` | `1` | `vLLM Metrics` | `ad9dcm5` | https://grafana.com/grafana/dashboards/25263-vllm-metrics/ |
| `24756` | `1` | `vLLM Monitoring - V2` | `vllm-master-v2` | https://grafana.com/grafana/dashboards/24756-vllm-monitoring-v2/ |

To reproduce them after losing Grafana's worker-local PVC, open **Dashboards ->
New -> Import**, enter each catalog ID, select revision 1 when available, and map
its Prometheus input to the `Prometheus` data source created by the monitoring
chart. Confirm the imported title before saving.

These are third-party dashboards, not repository-owned definitions. Their current
state persists in Grafana's 5 GiB PVC, while the ID/revision pair above identifies
the imported catalog artifact. Review imported PromQL and panel behavior after
vLLM or dashboard upgrades. The repository-owned `Qwen3 vLLM and GPU Overview`
dashboard remains declarative in `dashboard.yaml`.

Use Prometheus directly when diagnosing discovery:

```bash
kubectl --namespace monitoring port-forward \
  service/monitoring-kube-prometheus-prometheus 9090:9090
```

Open `http://127.0.0.1:9090/targets` and require the vLLM and DCGM targets to be
UP. Useful PromQL checks are:

```promql
up{namespace="llm-system"}
up{namespace="gpu-operator"}
vllm:num_requests_running
DCGM_FI_DEV_GPU_UTIL
```

## Data And Cleanup

Metrics and Grafana state are lab-local and disappear when their worker-local PVs
or the infrastructure are destroyed. They survive pod restarts on the same
worker. Export screenshots or benchmark evidence before teardown.
