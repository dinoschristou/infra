# Encrypt the vault.yaml file
encrypt:
    ansible-vault encrypt vars/vault.yaml

# Decrypt the vault.yaml file
decrypt:
    ansible-vault decrypt vars/vault.yaml

# Install Ansible requirements
ansible-reqs:
    ansible-galaxy install -r requirements.yaml

# Install Python requirements
python-reqs:
    pip install -r requirements.txt --user

# Run all roles across all servers, skipping dns, nut, nut_client, and test
run:
    ansible-playbook -i inventory/hosts.yaml site.yaml --skip-tags dns,nut,nut_client,test

# Run everything on a specific machine, skipping dns
run-machine host:
    ansible-playbook -i inventory/hosts.yaml site.yaml --skip-tags dns --limit {{host}}

# Push configurations to a specific machine
push-configs host:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags configs --limit {{host}}

# Update DNS entries on Pi-holes
update-dns:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags dns --limit piholes

# Change SSH port on a specified host
setup-ssh host:
    ansible-playbook -i inventory/hosts.yaml playbooks/change-ssh-port.yml --limit {{host}}

# Run site on cloud servers, skipping dns
run-ext:
    ansible-playbook -i inventory/hosts.yaml site.yaml --skip-tags dns --limit cloud

# Configure UPS server on pve3
nut-server:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags nut --limit pve3

# Configure UPS client on pve1,pve2
nut-client:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags nut_client --limit pve1,pve2

# Run only configs on a specified host
config-only host:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags config --limit {{host}}

# Test new roles on test_hosts
test-new-roles:
    ansible-playbook -i inventory/hosts.yaml site.yaml --tags test --limit test_hosts

# Run cluster up playbook
cluster-up:
    ansible-playbook -i inventory/hosts.yaml cluster-up.yaml

# Run cluster down playbook
cluster-down:
    ansible-playbook -i inventory/hosts.yaml cluster-down.yaml

# Generate new configuration files
new-config service:
    echo "Generating new configuration files in {{justfile_directory()}}/configs"
    mkdir -p {{justfile_directory()}}/configs/{{service}}
    cp {{justfile_directory()}}/configs/ztemplate/docker-compose.yaml {{justfile_directory()}}/configs/{{service}}/docker-compose.yaml
    cp {{justfile_directory()}}/configs/ztemplate/.env.st {{justfile_directory()}}/configs/{{service}}/.env.st
