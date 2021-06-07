# Ansible deployment for the Web Lab

This repository contains Ansible playbooks and roles for deploying the full Web Lab environment completely automatically.

Two methods of installation are provided: A "dev" deployment on a virtual machine, and a "production" deployment on a dedicated server.

## Deploying a dev environment

You can either use [Vagrant](https://www.vagrantup.com/) to create a complete virtual machine for you, or set up a VM manually.

Either way, you will need to edit some parts of `group_vars/dev/vars.yml` for your setup.

First, clone this repository and the submodules it uses:
```shell
git clone git@github.com:ModellingWebLab/deployment.git
cd deployment
git submodule update --init
```
### Running at a sub-URL

If you're hosting WebLab at a sub-URL on a domain (e.g. http://myhost.com/weblab/ rather than just http://myhost.com/) then edit `roles/django/templates/deployed.j2` and add the following lines with the correct URL prefix name, e.g.:

```
FORCE_SCRIPT_NAME = '/weblab/'
STATIC_URL = '/weblab/static/'
LOGIN_REDIRECT_URL = '/weblab/'
LOGOUT_REDIRECT_URL = '/weblab/'
```

### Using Vagrant

Version 2.2 of Vagrant is required for this. We recommend using the VirtualBox provider with it.

You may need to edit some options in the `Vagrantfile` depending on how you have configured your local variables.
For instance, remove the `raw_arguments` if you're not encrypting any secrets.

You will need to add a file `group_vars/dev/vault.yml`. This file needs to contain

    # Encrypted variable definitions specific to a dev environment (i.e. on a local VM)

    # If you want to send errors from your local instance to rollbar,
    # you can create an account there and put the token here
    vault_rollbar_post_server_item_access_token: ''

    # Your email information goes here: Web Lab needs to use your email account to send mail
    # Also check the non-sensitive settings in vars.yml are correct for your provider
    vault_email_smtp_host: ' ... '  # e.g. smtp.gmail.com or smtp-mail.outlook.com
    vault_email_smtp_user: ' ... '
    vault_email_smtp_password: ' ... '

Next, create a file `dev-vault-pw` in the `deployment` directory (or wherever you cloned the repository into), and add an arbitrary password there.
Now encrypt the file, by running
```shell
ansible-vault encrypt --vault-id=dev@dev-vault-pw group_vars/dev/vault.yml
```

Install the `vagrant-disksize` plugin so the initial virtual disk size can be set:
```shell
vagrant plugin install vagrant-disksize
```

Finally, run
```shell
vagrant up
```
within the root folder of this repository to start the virtual machine, and install everything on it.

If this fails, make appropriate changes (and update these instructions!), and run
```shell
vagrant up --provision
```
#### Add initial admin/superuser

To add an initial superuser for Django, use `vagrant ssh` to connect to the VM once provisioned and then run
```shell
cd /opt/django/WebLab/weblab/
sudo -u weblab_django /opt/django/venv/bin/python ./manage.py createsuperuser --settings config.settings.deployed
```
and fill in the prompts.
(Note that the `vagrant` user has password `vagrant` by default.)

You should then be able to connect to the Web Lab at http://localhost:8088/ and log in with your superuser credentials.
To test an experiment run, add a model and protocol sourced from https://chaste.cs.ox.ac.uk/WebLab and launch from the Experiments page.

#### Trying out new things

You can also change the `django_git_branch` (and/or add further variables) and re-run `vagrant provision` to re-deploy.

#### Note on installing vagrant on Windows

A very straightforward explanation of how to install everything necessary to run vagrant can be found [here](https://www.youtube.com/watch?v=zHgUQnYpo_g).

### Using the VM as a back-end for Django on the host

When doing front-end development it is useful to be able to run Django in developer mode on your local machine.
However, setting up the experiment runner back-end is non trivial.
In such circumstances you can connect a front-end Django instance to the web service running inside a Vagrant machine deployed as above.
The default `config/settings/dev.py` is set up to enable this, and works out of the box on Linux and Mac OS.

On Windows you may need to adapt the `CALLBACK_BASE_URL` Django setting and map port 8000 on the guest to port 8000 on the host.
This can be done with the command
```shell
vagrant ssh -- -R 8000:localhost:8000
```

### Manual virtual machine setup

To get started, create a virtual machine with a default install of Ubuntu 18.04.
Then run
```shell
sudo apt install python3-dev python3-venv
python3 -m venv ~/deploy_env
source ~/deploy_env/bin/activate
pip install --upgrade pip
pip install ansible
ansible-playbook -i inventories/dev site.yml --ask-become-pass -e 'django_git_branch=master' \
    -e 'django_superuser_email="my.email@domain"' \
    -e 'django_superuser_full_name="My Full Name"' \
    -e 'django_superuser_institution="My Institution"'
```

You only need to use the `superuser` stanzas for the initial deploy.


## Deploying on a cloud virtual machine

Create a new "Ubuntu Server 18.04 LTS" virtual machine using your preferred cloud provider.
We recommend at least 4GB RAM and 40GB disk, e.g. a Standard B2s on Azure.
How much beyond that you purchase depends on your desired price/performance trade-off.

Make sure you allow inbound access on ports 80 (HTTP), 443 (HTTPS) and 22 (SSH), either for everyone or just for your IP address.

You will also need to give the machine a valid public domain name, or the certbot certificate generation will fail.
This may need to be done after creating the VM (e.g. via the Azure portal) so we specify the name in the Ansible call below to avoid picking up a default internal one.

Add an administrator user account for yourself, ideally with SSH public key authentication.

Example cloud-init file (change the webserver_fqdn and superuser details to match your setup):
```yaml
#cloud-config
package_update: true
package_upgrade: true
packages:
  # Just the minimum needed to install Ansible 2.8
  - python3-pip
  - libffi-dev
  - libssl-dev
write_files:
  # Store extra vars for Ansible in a config file
  - path: /etc/weblab_ansible_vars.json
    content: "{
      'webserver_fqdn': 'weblab-example.uksouth.cloudapp.azure.com',
      'django_git_branch': 'master',
      'celery_git_branch': 'master',
      'weblab_fc_branch': 'master',
      'django_superuser_email': 'my.email@my.domain',
      'django_superuser_full_name': 'My Full Name',
      'django_superuser_institution': 'My Institution' }"
    owner: root:root
    permissions: '0644'
runcmd:
  - pip3 install cryptography==2.5 ansible==2.8
  - >-
    /usr/local/bin/ansible-pull -U https://github.com/ModellingWebLab/deployment -C master
    -d /opt/weblab_deploy_repo -i inventories/cloud --accept-host-key
    -e "@/etc/weblab_ansible_vars.json"
    site.yml
```

To watch the progress of the Ansible build, log in to your server and run `sudo journalctl -f`.
Logs will appear eventually at `/var/log/cloud-init-output.log`.

You can run `sudo ansible-pull` again on the host after the first deployment if you wish to update the system live.
The same options should work, or run `sudo -H /var/lib/cloud/instance/scripts/runcmd` as a shortcut.
Manually editing the `/etc/weblab_ansible_vars.json` JSON file will allow you to change variables passed to ansible,
while the `-C` argument specifies the deployment repository branch to use.


## Deploying on production

To deploy, run e.g.
```shell
ansible-playbook --vault-id main@prompt -i inventories/production site.yml --ask-become-pass -e 'django_git_branch=master'
```

For the initial deployment, you may also wish to create a superuser account:
```shell
ansible-playbook --vault-id main@prompt -i inventories/production site.yml -K -e 'django_git_branch=master' \
    -e 'django_superuser_email="my.email@domain"' \
    -e 'django_superuser_full_name="My Full Name"' \
    -e 'django_superuser_institution="My Institution"'
```

You can also deploy just part of the full system, use different branches,
store the Vault password in a file, and indeed override other Ansible variables with further `-e` flags.
```shell
ansible-playbook --vault-id main@$HOME/vault-main -i inventories/production -K -e 'django_git_branch=experiments' task_queue.yml workers.yml
```

### Updating SSL certificates

At present the server certificates are hardcoded to a specific server within Oxford.
We hope to make this more flexible, initially to support both staging & production servers.
For systems that can use certbot, the cloud inventory (see above) supports this.

When a certificate update is required for production, the new certificate (and possibly private key) need to be provided in `roles/nginx/files/weblab.{crt,key}`.
The `weblab.crt` file needs to include the full certificate chain, with the server certificate first, then any intermediate certificates, and finally the root certificate.

The private key needs to be encrypted with `ansible vault`:
```sh
ansible-vault encrypt --vault-id=main@$HOME/vault-main roles/nginx/files/weblab.key
```

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

To restart Django:
```shell
sudo systemctl restart uwsgi
```
