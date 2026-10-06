# Reproduction Guide

This is the canonical execution order for rebuilding this lab or adapting it to
another model, GPU VM, region, or domain. Detailed rationale and component-level
checks remain in the linked READMEs. Commands assume the repository root as the
working directory and never authorize billable or destructive actions by
themselves.

## 1. Prepare Inputs And Tools

Required local tools are Azure CLI, Terraform, Ansible, OpenSSH, kubectl, Helm,
curl, jq, and OpenSSL. Compare installed versions with `docs/versions.md`.

Prepare these environment-specific inputs without committing them:

- Azure subscription and tenant.
- Current administrator public IPv4 `/32`.
- SSH public/private key pair.
- Hugging Face token permitted to download the selected model.
- DNS control for the public domain.
- ACME contact email.
- Runtime-generated vLLM, Open WebUI, and Grafana passwords.

Authenticate and confirm the intended subscription:

```bash
az login
az account show --output table
```

## 2. Provision Azure Infrastructure

Create the private variable file from the non-secret shape and review every
environment-specific value:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
chmod 600 terraform/terraform.tfvars
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init
terraform -chdir=terraform validate
terraform -chdir=terraform plan \
  -var-file=terraform.tfvars \
  -out=tfplan
terraform -chdir=terraform show tfplan
```

Check region, VM SKUs, Spot priority and ceiling, disks, public/private IPs, NSG
sources, and the create/update/delete summary. Only after explicit approval:

```bash
terraform -chdir=terraform apply tfplan
terraform -chdir=terraform output
```

Terraform details, quotas, and plan-review criteria are in
`terraform/README.md` and `docs/costs.md`.

## 3. Configure Hosts And Bootstrap kubeadm

Copy and edit the private inventory using Terraform's public IP outputs:

```bash
cp ansible/inventory/hosts.example.yml ansible/inventory/hosts.yml
chmod 600 ansible/inventory/hosts.yml
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --check --diff
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --diff
ansible-playbook -i ansible/inventory/hosts.yml ansible/site.yml --diff
ansible-playbook -i ansible/inventory/hosts.yml ansible/cluster.yml --diff
```

The second `site.yml` run should have no unexpected changes. Validate host GPU
support before installing cluster add-ons:

```bash
ansible gpu_workers -i ansible/inventory/hosts.yml -a 'nvidia-smi'
ansible gpu_workers -i ansible/inventory/hosts.yml -a 'nvidia-container-cli info'
```

The complete host and kubeadm procedure is in `ansible/README.md`.

## 4. Establish Private kubectl Access

Copy `/etc/kubernetes/admin.conf` securely from the control plane to a local file
outside source control. Keep its server at `https://10.42.0.10:6443`, configure a
SOCKS proxy, and keep the tunnel open:

```bash
chmod 600 ./kubeconfig
kubectl --kubeconfig ./kubeconfig config set-cluster kubernetes \
  --server=https://10.42.0.10:6443 \
  --proxy-url=socks5://127.0.0.1:1080
ssh -N -D 127.0.0.1:1080 \
  -i ~/.ssh/llmplat_ed25519 \
  sauravkarki@<CONTROL_PLANE_PUBLIC_IP>
```

In another terminal:

```bash
kubectl --kubeconfig ./kubeconfig cluster-info
kubectl --kubeconfig ./kubeconfig get nodes -o wide
```

Use `--kubeconfig ./kubeconfig` on subsequent commands if `KUBECONFIG` is not
exported. Never commit this administrator credential.

## 5. Install Networking, Storage, And GPU Integration

Run the exact ordered commands in `k8s/README.md`:

1. Install Calico `3.32.2` CRDs and operator.
2. Wait for both nodes and CoreDNS to become Ready.
3. Apply `k8s/storage` and pass the local-path smoke test.
4. Install GPU Operator `26.7.1` with `k8s/gpu-operator/values.yaml` and the
   documented initial ServiceMonitor override.
5. Require `nvidia.com/gpu=1` and pass `cuda-validation.yaml`.

Do not proceed when an earlier gate is unhealthy.

## 6. Deploy vLLM And Qwen3

Create runtime-only secrets as described in `helm/vllm/README.md`, then install:

```bash
helm lint helm/vllm
helm template vllm helm/vllm --namespace llm-system >/tmp/vllm.yaml
helm upgrade --install vllm helm/vllm \
  --namespace llm-system \
  --set serviceMonitor.enabled=false \
  --wait --timeout 35m
```

The current serving profile uses BF16, one GPU, an 8,192-token served context,
Qwen3 reasoning parsing, Hermes tool-call parsing, and automatic tool choice.
Verify health, unauthenticated HTTP 401, authenticated model listing, and an
authenticated chat completion before adding the UI.

## 7. Publish DNS, TLS, And Routes

Point an A record for the chosen hostname to the GPU worker public IP and keep it
DNS-only during HTTP-01 issuance. Update the hostname and ACME email in
`k8s/edge/` before applying another environment.

Run the pinned commands in `k8s/edge/README.md`. The managed Envoy pod listens on
unprivileged container ports `10080` and `10443`; Kubernetes maps them to worker
host ports 80 and 443. Verify:

```bash
kubectl get gateway,httproute --all-namespaces
kubectl --namespace edge-system get certificate,certificaterequest,challenge
curl --head http://<DOMAIN>/
curl --head https://<DOMAIN>/
curl --output /dev/null --write-out '%{http_code}\n' https://<DOMAIN>/v1/models
```

Expected results are HTTP-to-HTTPS redirect, valid public TLS, Open WebUI HTTP
200, and unauthenticated vLLM HTTP 401.

## 8. Deploy Open WebUI

Create the two runtime Secrets documented in `k8s/open-webui/README.md`. Copy the
vLLM API key between Secrets without printing it, and generate the administrator
password at runtime. Install chart `16.6.0` and apply the route.

Sign in with `WEBUI_ADMIN_EMAIL` and the generated password. Send a basic prompt
and confirm the selected `Qwen/Qwen3-8B` model returns content. If the UI sends
automatic tool definitions, vLLM requires the tool flags already represented by
the chart. The 8,192-token context leaves room for the UI system/tool prompt and
generation output.

## 9. Deploy Monitoring

Follow `k8s/monitoring/README.md` exactly. Install kube-prometheus-stack `91.8.2`,
apply the version-controlled dashboard, and upgrade GPU Operator and vLLM so their
ServiceMonitors are created after the CRDs exist.

Grafana remains private. Reach it with port-forwarding, require vLLM and DCGM
targets to be UP, generate inference traffic, and confirm the custom dashboard
shows request, latency, token, KV-cache, GPU utilization, and framebuffer series.
For parity with the verified environment, import Grafana community dashboard
`25263` revision 1 and dashboard `24756` revision 1, mapping both to the
`Prometheus` data source. Their local titles and UIDs are recorded in
`k8s/monitoring/README.md`.

## 10. Capture Evidence And Shut Down

Before stopping compute, update `docs/runtime-evidence.md` with redacted command
results and export required screenshots. Never record API keys, passwords,
Hugging Face tokens, authorization headers, private keys, or sensitive prompts.

VM deallocation and infrastructure destruction are separate decisions. After
explicit shutdown approval:

```bash
az vm deallocate --resource-group rg-kube-vllm-eastasia \
  --name kube-vllm-gpu-worker
az vm deallocate --resource-group rg-kube-vllm-eastasia \
  --name kube-vllm-control-plane
az vm list --resource-group rg-kube-vllm-eastasia \
  --show-details --output table
```

Deallocation stops VM compute billing but retains disks and public IP resources.
Only an explicitly approved, freshly reviewed `terraform destroy` removes the
declared infrastructure.

## Adapting The Project

For another model or GPU, review model license/revision, image support, VRAM for
weights and KV cache, dtype/quantization, context length, tokenizer/chat template,
reasoning/tool parsers, disk size, CUDA/driver compatibility, and benchmark gates.
For another region or domain, update Terraform region/quota assumptions, DNS,
Gateway hostnames, ACME contact, cost evidence, and every environment-specific
verification command.
