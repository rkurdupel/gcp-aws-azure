#!/bin/bash
vagrant up devops-data

# generate known_hosts ssh keys for ansible
  : > ansible/known_hosts
  ssh-keyscan -H 192.168.56.14 >> ansible/known_hosts

ansible-playbook ansible/site.yml --ask-vault-pass
docker compose up 