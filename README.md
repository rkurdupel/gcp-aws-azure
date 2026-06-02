# Coin-Ops

Multi-cloud infrastructure and application stack for tracking prediction-market and currency data.

The repo contains:

- Terraform modules for AWS, GCP, and Azure VM networking and compute
- Ansible playbooks for node provisioning, k3s, CloudNativePG, cert-manager, Headlamp, Homepage, and the Coin-Ops app
- A Kubernetes deployment layer built on a multi-node k3s cluster
- A React/Vite frontend served by nginx
- A Go proxy API that fetches Polymarket, CoinGecko, and NBU data
- A Python FastAPI history API and consumer for persisted market and price snapshots
- Local Docker Compose wiring for development

## Architecture

Local development runs all application services with Docker Compose:

```text
browser
  -> ui nginx (:5000)
      -> proxy API (:8080)
      -> history API (:8000)
          -> PostgreSQL
proxy API -> Redis
proxy API -> RabbitMQ -> history consumer -> PostgreSQL
```

Cloud infrastructure is driven by `config/config.yml`.

```text
operator
  -> bastion VM
      -> k3s nodes
          -> Coin-Ops workloads
          -> RabbitMQ / Redis
          -> CloudNativePG PostgreSQL
```

AWS also includes optional managed resources in the Terraform module, including an ALB, ACM, Cloudflare DNS integration, and RDS outputs. GCP and Azure currently focus on VM/network provisioning.

## Kubernetes Stack

Cloud deployments run on k3s, a lightweight Kubernetes distribution installed by Ansible on the `k3s-node-*` VMs. The stack includes:

- k3s cluster nodes managed by `ansible/cloud-k3s.yml`
- CloudNativePG (CNPG) operator and PostgreSQL cluster managed by `ansible/cloud-cnpg.yml`
- cert-manager and Cloudflare DNS challenge issuers for TLS certificates
- Coin-Ops application workloads in Kubernetes: UI, Go proxy, history API, history consumer, RabbitMQ, Redis, and PostgreSQL bootstrap job
- Traefik ingress routing for the public app domain
- Optional Headlamp and Homepage add-ons for cluster UI and dashboard access

The Kubernetes manifests are rendered from Ansible role templates under `ansible/roles/k3s_coinops/templates/`.

## Repository Layout

```text
.
+-- ansible/                 # cloud provisioning and k3s application deployment
+-- config/config.yml        # cloud, region, SSH, network, and instance configuration
+-- deploy/                  # deploy-time Docker/Kubernetes support assets
+-- history/                 # FastAPI history API and RabbitMQ/Postgres consumer
+-- proxy/                   # Go HTTP API and data-fetching service
+-- runtime/                 # PostgreSQL runtime schema, wrappers, cron, tests
+-- scripts/                 # terraform apply helper, inventory generation, verification
+-- terraform/               # root Terraform stack and cloud modules
+-- ui-react/                # React/Vite frontend
+-- docker-compose.yml       # local development stack
```

## Prerequisites

For local development:

- Docker and Docker Compose
- Node.js and npm, if working on `ui-react` directly
- Go, if working on `proxy` directly
- Python 3.10+, if working on `history` directly

For cloud deployment:

- Terraform 1.5+
- Ansible 2.14+
- AWS CLI, Google Cloud CLI, and/or Azure CLI for the clouds you use
- `jq`
- An SSH key matching `config/config.yml`
- Cloud provider credentials exported in your shell

## Configuration

Copy the example environment file and edit the values:

```bash
cp .env.example .env
source .env
```

Important variables:

```bash
# Cloud credentials
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_DEFAULT_REGION=eu-central-1
export SUBSCRIPTION_ID=...
export AZURE_AUTH_LOCATION=/path/to/sp-key.json

# Terraform variables
export TF_VAR_cloudflare_api_token=...
export TF_VAR_cloudflare_zone_id=...
export TF_VAR_domain_name=coin-ops.pp.ua
export TF_VAR_db_name=currency_rates_tracker
export TF_VAR_db_user=currency_app_user
export TF_VAR_db_password=...

# Application secrets
export POSTGRES_USER=currency_app_user
export POSTGRES_PASS=...
export POSTGRES_DB=currency_rates_tracker
export RABBITMQ_USER=currency_app_user
export RABBITMQ_PASS=...
export REDIS_PASSWORD=...

# SSH
export SSH_KEY_PATH=~/.ssh/id_ed25519
```

The active cloud and VM layout are controlled in `config/config.yml`:

```yaml
cloud: gcp # aws | gcp | azure

instances:
  bastion:
    public: true
    private_ip: 10.10.0.10
    tags:
      - bastion
  k3s-node-1:
    public: true
    private_ip: 10.10.1.11
    tags:
      - k3s-node
```

An instance can override the top-level cloud by adding `cloud: aws`, `cloud: gcp`, or `cloud: azure`.

## Local Development

Start the full local stack:

```bash
docker compose up --build
```

Open the UI:

```text
http://localhost:5000
```

Useful local endpoints:

```text
http://localhost:5000/api/health
http://localhost:5000/api/current
http://localhost:5000/api/prices
http://localhost:5000/history-api/health
```

Stop the stack:

```bash
docker compose down
```

Remove local database state:

```bash
docker compose down -v
```

## Frontend Development

```bash
cd ui-react
npm install
npm run dev
```

The frontend defaults to:

```text
PROXY_URL=/api
HISTORY_URL=/history-api
```

For standalone Vite development, set `VITE_PROXY_URL` and `VITE_HISTORY_URL` or use the runtime config in `ui-react/public/config.js`.

## Cloud Bootstrap

Run the bootstrap script only for the clouds you plan to use. These scripts create or prepare state storage and cloud identities.

```bash
# AWS
bash bootstrap-aws.sh

# GCP
export BILLING_ACCOUNT_ID=...
bash bootstrap-gcp.sh

# Azure
export SUBSCRIPTION_ID=...
bash bootstrap-azure.sh
```

After bootstrap, reload your environment:

```bash
source .env
```

## Cloud Deployment

1. Choose the target cloud and instance layout in `config/config.yml`.

2. Create or update infrastructure:

```bash
cd terraform
terraform init
terraform plan
terraform apply
cd ..
```

3. Generate Ansible inventory and SSH config:

```bash
./scripts/post-apply.sh
```

This writes:

- `ansible/inventory.cloud`
- `~/.ssh/coinops-aws.generated`

4. Provision and deploy the Kubernetes stack:

```bash
source .env
ansible-playbook -i ansible/inventory.cloud ansible/cloud-provision.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-k3s.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-cnpg.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-cert-manager.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-coinops.yml
```

Optional add-ons:

```bash
ansible-playbook -i ansible/inventory.cloud ansible/cloud-headlamp.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-homepage.yml
ansible-playbook -i ansible/inventory.cloud ansible/cloud-tailscale.yml
```

5. Verify SSH access:

```bash
ssh coinops-bastion
ssh coinops-k3s-node-1
ssh coinops-k3s-node-2
ssh coinops-k3s-node-3
```

6. Destroy lab infrastructure when finished:

```bash
cd terraform
terraform destroy
```

## Helper Scripts

`scripts/post-apply.sh` reads Terraform outputs, writes Ansible inventory, writes an SSH include file, clears old known-host entries, and records the RDS endpoint in `.env` when present.

`scripts/lab.sh apply` runs Terraform apply and then `post-apply.sh`.

`scripts/lab.sh verify` runs `scripts/verify_failover.sh`.

The `deploy` and `full` subcommands in `scripts/lab.sh` still reference an older Ansible deployment playbook name. Prefer the explicit Ansible commands above until that helper is updated.

## Tests

Frontend:

```bash
cd ui-react
npm run lint
npm run test:run
npm run build
```

Go proxy:

```bash
cd proxy
go test ./...
```

Python history service dependencies:

```bash
cd history
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
```

No Python test files are currently checked in. `history/pytest.ini` is ready for tests under `tests/python/unit`.

PostgreSQL runtime SQL:

```bash
psql "$DATABASE_URL" -f runtime/runtime_all.sql
psql "$DATABASE_URL" -f runtime/tests/test_runtime.sql
```

## Operational Notes

- `config/config.yml` is the source of truth for cloud selection, regions, instance sizes, images, network ranges, and SSH settings.
- Cross-cloud private networking is not automatic. Instances in different clouds need an overlay or VPN such as Tailscale.
- Private k3s nodes are reached through the bastion using the generated SSH config.
- The k3s app role uses Docker images defined in `ansible/roles/k3s_coinops/defaults/main.yml`.
- Cloud costs continue until resources are destroyed. Run `terraform destroy` when the lab is no longer needed.

## Troubleshooting

Regenerate inventory after every Terraform apply:

```bash
./scripts/post-apply.sh
```

If SSH host keys changed after recreating VMs:

```bash
ssh-keygen -R 10.10.0.10
ssh-keygen -R 10.10.1.11
ssh-keygen -R 10.10.1.12
ssh-keygen -R 10.10.1.13
./scripts/post-apply.sh
```

Check Terraform outputs:

```bash
cd terraform
terraform output vm_ips
terraform output ansible_inventory
terraform output ssh_config
terraform output alb_dns_name
terraform output rds_endpoint
```

Check local containers:

```bash
docker compose ps
docker compose logs -f proxy
docker compose logs -f history-api
docker compose logs -f history-consumer
```
