# Ansible Deployment

## Responsibility

Ansible provisions only the `devops-data` VM.

It is responsible for:

- installing common packages
- configuring timezone and time sync
- installing and configuring PostgreSQL
- installing and configuring RabbitMQ
- installing and configuring Redis

It does not deploy the application services. The `ui`, `proxy`, and `history` services run through Docker Compose.

## Entry Points

- inventory: `inventory.ini`
- playbook: `site.yml`
- host vars: `host_vars/devops-data.yml`
- shared vars: `group_vars/all/main.yml`
- shared secrets: `group_vars/all/vault.yml`

## Inventory

Current inventory:

```ini
[data]
devops-data ansible_host=192.168.56.14

[all:vars]
ansible_user=vagrant
```

Current host-specific SSH key path:

```yaml
ansible_ssh_private_key_file: "{{ playbook_dir }}/../.vagrant/machines/devops-data/virtualbox/private_key"
```

## Variable Layout

### Non-secret Variables

`group_vars/all/main.yml` contains shared non-secret values used by the data-layer roles, including:

- `postgres_host`
- `rabbitmq_host`
- `redis_host`
- `postgres_db`
- `postgres_table`
- `postgres_user`
- `rabbitmq_user`
- `rabbitmq_queue`
- `redis_port`

### Secret Variables

`group_vars/all/vault.yml` should contain the encrypted secrets required by the data-layer roles, such as:

- `postgres_password`
- `pgadmin_login`
- `pgadmin_login_password`
- `rabbitmq_password`
- `redis_password`

## Provisioning Flow

`site.yml` currently applies:

1. `common` to all hosts
2. `postgres`, `rabbitmq`, and `redis` to the `data` host

That means the supported provisioning sequence is:

1. start `devops-data`
2. refresh `ansible/known_hosts`
3. run the Ansible playbook

## Commands

### Full Provisioning

```bash
ansible-playbook ansible/site.yml --ask-vault-pass
```

### Provision Only The Data Host

```bash
ansible-playbook ansible/site.yml --limit data --ask-vault-pass
```

### View The Vault

```bash
ansible-vault view ansible/group_vars/all/vault.yml
```

### Prepare SSH Host Keys

```bash
: > ansible/known_hosts
ssh-keyscan -H 192.168.56.14 >> ansible/known_hosts
```

## Vault

If decryption fails, check:

- the vault password is correct
- the encrypted file is `ansible/group_vars/all/vault.yml`
- you are not pointing Ansible at the wrong file

## Troubleshooting

### SSH Fails

Check:

- `devops-data` is running
- `ansible/known_hosts` was refreshed
- the private key path in `host_vars/devops-data.yml` points to the current Vagrant machine

Useful commands:

```bash
vagrant status
vagrant ssh devops-data
```

### PostgreSQL Is Unavailable After Provisioning

Check:

```bash
vagrant ssh devops-data -c "sudo systemctl status postgresql"
```

If needed, rerun only provisioning:

```bash
ansible-playbook ansible/site.yml --limit data --ask-vault-pass
```

### RabbitMQ Is Unavailable After Provisioning

Check:

```bash
vagrant ssh devops-data -c "sudo systemctl status rabbitmq-server"
vagrant ssh devops-data -c "sudo rabbitmqctl list_users"
```

### Redis Is Unavailable After Provisioning

Check:

```bash
vagrant ssh devops-data -c "sudo systemctl status redis-server"
```

### Time Or Timezone Looks Wrong

The provisioning roles configure timezone and chrony on the data VM. Verify:

```bash
vagrant ssh devops-data -c "date"
vagrant ssh devops-data -c "timedatectl"
```
