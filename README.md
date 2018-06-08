# Ansible deployment for the Web Lab

This repository contains Ansible playbooks and roles for deploying the
full Web Lab environment completely automatically.

To deploy, run e.g.
```shell
ansible-playbook --vault-id main@prompt -i production site.yml -K -e 'django_git_branch=master'
```

For the initial deployment, you may also wish to create a superuser account:
```shell
ansible-playbook --vault-id main@prompt -i production site.yml -K -e 'django_git_branch=master' \
    -e 'django_superuser_email="my.email@domain"' \
    -e 'django_superuser_full_name="My Full Name"' \
    -e 'django_superuser_institution="My Institution"'
```

At present the server certificates are hardcoded to a specific server within Oxford.
We hope to make this more flexible, especially to support both staging & production servers;
ideally also a developer setup on a local VM.
