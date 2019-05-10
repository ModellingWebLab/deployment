# Ansible deployment for the Web Lab

This repository contains Ansible playbooks and roles for deploying the
full Web Lab environment completely automatically.

## Deploying a dev environment

You can either use [Vagrant](https://www.vagrantup.com/) to create a complete virtual machine for you,
or set up a VM manually.

Either way, you will need to edit some parts of `group_vars/dev/vars.yml` for your setup.

First, clone this repository and the submodules it uses:
```shell
git clone git@github.com:ModellingWebLab/deployment.git
cd deployment
git submodule update --init
```

### Using Vagrant

Simply run `vagrant up` within the root folder of this repository.

You may need to edit some options in the `Vagrantfile` depending on how you have configured your local variables.
For instance, remove the `raw_arguments` if you're not encrypting any secrets.

You can also change the `django_git_branch` (and/or add further variables) and re-run `vagrant provision` to re-deploy.

To add an initial superuser for Django, use `vagrant ssh` to connect to the VM once provisioned and then run
```shell
cd /opt/django/WebLab/weblab/
sudo -u weblab_django /opt/django/venv/bin/python ./manage.py createsuperuser --settings config.settings.deployed
```
and fill in the prompts.
(Note that the `vagrant` user has password `vagrant` by default.)

You should then be able to connect to the Web Lab at http://localhost:8088/ and log in with your superuser credentials.
To test an experiment run, add a model and protocol sourced from https://chaste.cs.ox.ac.uk/WebLab and launch from the Experiments page.

### Using the VM as a back-end for Django on the host

When doing front-end development it is useful to be able to run Django in developer mode on your local machine.
However, setting up the experiment runner back-end is non trivial.
In such circumstances you can connect a front-end Django instance to the web service running inside a Vagrant machine deployed as above.
The default `config/settings/dev.py` is set up to enable this.
In addition, you will need to map port 8000 on the guest to port 8000 on the host.
This can be done with the command
```shell
vagrant ssh -- -R 8000:localhost:8000
```

### Manual virtual machine setup

To get started, create a virtual machine with a default install of Ubuntu 16.04.
Then run
```shell
sudo apt install python3-dev python3-venv
python3 -m venv ~/deploy_env
source ~/deploy_env/bin/activate
pip install --upgrade pip
pip install ansible
ansible-playbook -i dev site.yml --ask-become-pass -e 'django_git_branch=master' \
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
We hope to make this more flexible, initially to support both staging & production servers.

## Handy commands on the deployed server

To view Django log output:
```shell
journalctl -t weblab --since today  # Show all today's logs
journalctl -t weblab --since 17:04  # See today's logs from the given time
journalctl -t weblab --since -10m   # Show the last 10 minutes' logs
journalctl -t weblab -f             # Act like tail -f
```

Celery worker logs are in `/var/log/celery/`.

To launch a Django shell:
```shell
sudo -u weblab_django /opt/django/venv/bin/python /opt/django/WebLab/weblab/manage.py shell --settings config.settings.deployed
```
or
```shell
sudo su - weblab_django
source /opt/django/venv/bin/activate
cd /opt/django/WebLab/weblab
./manage.py shell --settings config.settings.deployed
```
