# Open WebUI

Open WebUI connects to the internal vLLM Service and stores its SQLite database
on a node-local PVC. Ollama, Pipelines, and Redis are disabled for this
single-replica lab deployment.

Two Secrets must exist before installation:

- `open-webui-vllm-api` with key `api-key`, copied from the vLLM API Secret.
- `open-webui-admin` with `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_NAME`, and a generated
  `WEBUI_ADMIN_PASSWORD`.

Create them without printing credential values:

```bash
kubectl create namespace open-webui --dry-run=client -o yaml | kubectl apply -f -
VLLM_API_KEY="$(kubectl --namespace llm-system get secret vllm-api-key \
  --output 'jsonpath={.data.api-key}' | base64 --decode)"
kubectl --namespace open-webui create secret generic open-webui-vllm-api \
  --from-literal="api-key=${VLLM_API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset VLLM_API_KEY

WEBUI_ADMIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
kubectl --namespace open-webui create secret generic open-webui-admin \
  --from-literal=WEBUI_ADMIN_EMAIL=admin@llm.ksaurav.com.np \
  --from-literal=WEBUI_ADMIN_NAME=Administrator \
  --from-literal="WEBUI_ADMIN_PASSWORD=${WEBUI_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset WEBUI_ADMIN_PASSWORD
```

The admin password is intentionally not stored in Git. Retrieve it from the
cluster only when needed:

```bash
kubectl --namespace open-webui get secret open-webui-admin \
  --output 'jsonpath={.data.WEBUI_ADMIN_PASSWORD}' | base64 --decode
```

Install the pinned chart and route:

```bash
helm upgrade --install open-webui \
  oci://ghcr.io/open-webui/helm-charts/open-webui \
  --version 16.6.0 \
  --namespace open-webui \
  --create-namespace \
  --values k8s/open-webui/values.yaml

kubectl apply -f k8s/open-webui/route.yaml
```

Verify the Deployment and private Service before testing the public route:

```bash
kubectl --namespace open-webui get deployment,pod,service,pvc
curl --fail-with-body https://llm.ksaurav.com.np/ >/dev/null
```
