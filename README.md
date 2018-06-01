# Ansible deployment for the Web Lab

This repository contains Ansible playbooks and roles for deploying the
full Web Lab environment completely automatically.

## Deploying a dev environment

To get started, create a virtual machine with a default install of Ubuntu 16.04.
You will also need to edit some parts of `group_vars/dev/vars.yml` for your setup.
Then run
```shell
sudo apt install python3-dev python3-venv
python3 -m venv ~/deploy_env
source ~/deploy_env/bin/activate
pip install --upgrade pip
pip install ansible
ansible-playbook --vault-id dev@$HOME/vault-dev -i dev site.yml --ask-become-pass -e 'django_git_branch=master' \
    -e 'django_superuser_email="my.email@domain"' \
    -e 'django_superuser_full_name="My Full Name"' \
    -e 'django_superuser_institution="My Institution"'
```

Only use the `superuser` stanzas for the initial deploy.

## Deploying on production

To deploy, run e.g.
```shell
ansible-playbook --vault-id main@prompt -i production site.yml --ask-become-pass -e 'django_git_branch=master'
```

For the initial deployment, you may also wish to create a superuser account:
```shell
ansible-playbook --vault-id main@prompt -i production site.yml -K -e 'django_git_branch=master' \
    -e 'django_superuser_email="my.email@domain"' \
    -e 'django_superuser_full_name="My Full Name"' \
    -e 'django_superuser_institution="My Institution"'
```

You can also deploy just part of the full system, use different branches,
store the Vault password in a file, and indeed override other Ansible variables with further `-e` flags.
```shell
ansible-playbook --vault-id main@$HOME/vault-main -i production -K -e 'django_git_branch=experiments' task_queue.yml workers.yml
```

At present the server certificates are hardcoded to a specific server within Oxford.
We hope to make this more flexible, especially to support both staging & production servers;
ideally also a developer setup on a local VM.

## Handy commands on the deployed server

To view Django log output:
```shell
journalctl -t weblab --since today  # Show all today's logs
journalctl -t weblab --since 17:04  # See today's logs from the given time
journalctl -t weblab --since -10m   # Show the last 10 minutes' logs
journalctl -t weblab -f             # Act like tail -f
```
