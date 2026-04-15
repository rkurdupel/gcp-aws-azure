# Documentation Rewrite Design

## Goal

Rewrite the project documentation so it describes one supported deployment model only:

- `devops-data` VM provisioned by Vagrant and Ansible
- `ui`, `proxy`, and `history` running as Docker Compose services

The rewrite must remove outdated guidance for the retired `devops-ui`, `devops-proxy`, and `devops-history` VM-based application deployment.

## Scope

Documentation files to rewrite:

- `README.md`
- `ansible/README.md`
- `ui/README.md`
- `proxy_service/README.md`
- `history_service/README.md`

In scope:

- architecture explanation for the current deployment model
- setup and deployment instructions
- configuration guidance for `.env` and Ansible variables
- runtime responsibilities of each service
- practical troubleshooting sections
- command examples for provisioning, launching, and inspecting services

Out of scope:

- changing application behavior
- changing Docker networking behavior
- changing Ansible provisioning behavior beyond documentation accuracy
- adding new features or new deployment targets

## Current State Summary

The repository has already been partially simplified toward the target model:

- `Vagrantfile` now defines only `devops-data`
- `ansible/site.yml` now provisions only common packages plus PostgreSQL, RabbitMQ, and Redis on the data host
- Docker Compose continues to run `ui`, `proxy`, and `history`
- environment variables in `.env.example` already reflect Docker service-name routing for app-to-app traffic and the data VM IP for shared infrastructure

The remaining problem is documentation drift. Existing docs still describe:

- a four-VM architecture
- app-service deployment with Ansible and systemd
- host-specific instructions for `devops-ui`, `devops-proxy`, and `devops-history`
- obsolete troubleshooting for removed systemd units

## Target Documentation Model

The rewritten docs will describe this flow:

1. Start the data VM with Vagrant
2. Provision the data VM with Ansible
3. Prepare `.env` from `.env.example`
4. Start `ui`, `proxy`, and `history` with Docker Compose

Runtime relationships:

- browser -> `ui`
- `ui` -> `proxy`
- `ui` -> `history`
- `ui` -> Redis on `devops-data`
- `proxy` -> Coinbase API
- `proxy` -> RabbitMQ on `devops-data`
- `history` -> RabbitMQ on `devops-data`
- `history` -> PostgreSQL on `devops-data`

## Per-Document Plan

### `README.md`

Purpose:

- serve as the main lab guide
- explain the supported architecture end-to-end
- provide the main deployment and troubleshooting entry point

Sections:

- project overview
- architecture diagram for one data VM plus three containers
- repository structure
- prerequisites
- configuration
- deployment steps
- services and ports
- data flow
- useful commands
- troubleshooting

Removals:

- four-VM architecture as the supported model
- app-service systemd deployment sections
- app VM SSH instructions
- host assignments for removed app VMs

### `ansible/README.md`

Purpose:

- explain only the infrastructure that Ansible still manages

Sections:

- responsibility of Ansible in the current project
- inventory and playbook layout
- variables and vault
- provisioning steps for `devops-data`
- re-running data provisioning
- troubleshooting for vault, SSH, PostgreSQL, RabbitMQ, and Redis

Removals:

- inventory groups for `ui`, `proxy`, and `history`
- app-service systemd references
- commands targeting removed app hosts

### Service READMEs

Purpose:

- describe each application service as a Docker-run service in the current architecture

Shared structure:

- responsibility
- runtime
- endpoints
- dependencies
- environment variables
- Docker usage
- common problems

Removals:

- host VM identity for removed app VMs
- systemd unit references
- journalctl and systemctl commands for removed units
- Ansible-managed app deployment language

Service-specific notes:

- `ui/README.md` should explain dependency on Docker networking to reach `proxy` and `history`, plus Redis on `devops-data`
- `proxy_service/README.md` should explain live price fetches, RabbitMQ publishing, and the current refresh behavior
- `history_service/README.md` should explain queue consumption, PostgreSQL writes, and chart/history endpoints

## Writing Style

The docs will be written as a detailed lab guide:

- explicit commands rather than vague summaries
- operational explanations for why each step exists
- practical wording over marketing language
- enough context to understand the system without reading code first

Tone:

- technical and direct
- suitable for a portfolio or internship lab repository
- no legacy-path ambiguity

## Constraints

- Documentation must match the actual repo structure after the recent infrastructure cleanup.
- The rewrite should not claim support for paths that the repository no longer provisions.
- Service documentation should remain consistent with actual environment-variable usage in code.
- The rewrite should not introduce references to new tools or infrastructure that do not exist in the repository.

## Risks And Mitigations

### Risk: docs still reference removed VM deployment details

Mitigation:

- explicitly scan for `devops-ui`, `devops-proxy`, `devops-history`, `ui.service`, `proxy.service`, and `history.service`

### Risk: docs diverge from actual runtime configuration

Mitigation:

- base configuration sections on `docker-compose.yml`, `.env.example`, `Vagrantfile`, `ansible/site.yml`, and current service code

### Risk: root README becomes too long and repetitive

Mitigation:

- keep shared deployment flow in `README.md`
- keep service-specific operational details in service READMEs

## Verification

Before considering the documentation rewrite complete:

- confirm all rewritten docs reference only the supported deployment model
- scan for stale references to removed VM app hosts and removed systemd units
- verify command examples match current files and entry points
- verify service README environment variables match code

## Implementation Handoff

The implementation phase should rewrite the five documentation files in this order:

1. `README.md`
2. `ansible/README.md`
3. `ui/README.md`
4. `proxy_service/README.md`
5. `history_service/README.md`

After rewriting, run a final repository-wide search for obsolete deployment references before closing the task.
