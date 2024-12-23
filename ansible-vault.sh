#!/bin/bash

VAULT_ANSIBLE_NAME="Ansible Vault"

if [[ -z "${ANSIBLE_VAULT_PASS}" ]]; then
  op item get --format json "$VAULT_ANSIBLE_NAME" |jq '.fields[] | select(.id=="password").value' | tr -d '"'
else
  echo $ANSIBLE_VAULT_PASS
fi