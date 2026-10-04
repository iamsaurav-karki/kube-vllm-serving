# Public Edge

Envoy Gateway is deployed without a cloud load balancer. Its managed proxy pod
is pinned to `kube-gpu-worker`; Kubernetes maps Envoy's unprivileged listener
ports `10080` and `10443` to host ports 80 and 443. The Azure NSG already permits
Internet traffic on those public host ports.

The HTTP listener exists for ACME HTTP-01 and redirects all application traffic
to HTTPS. cert-manager attaches temporary challenge routes to that listener.

Install the pinned controllers before applying the custom resources:

```bash
helm upgrade --install envoy-gateway \
  oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.1 \
  --namespace envoy-gateway-system \
  --create-namespace \
  --values k8s/edge/envoy-gateway-values.yaml

helm upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.2 \
  --namespace cert-manager \
  --create-namespace \
  --values k8s/edge/cert-manager-values.yaml

kubectl apply -f k8s/edge/letsencrypt-issuer.yaml
kubectl wait --for=condition=Ready \
  clusterissuer/letsencrypt-production --timeout=3m
kubectl apply -f k8s/edge/gateway.yaml
kubectl apply -f k8s/edge/routes.yaml
```

The A record must resolve to the GPU worker before certificate issuance. Verify
controller, listener, route, and certificate state:

```bash
kubectl --namespace envoy-gateway-system get deployment,pod,service
kubectl get gateway,httproute --all-namespaces
kubectl --namespace edge-system wait --for=condition=Ready \
  certificate/llm-tls --timeout=8m
curl --head http://llm.ksaurav.com.np/
curl --head https://llm.ksaurav.com.np/
```
