# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

    # We need Ubuntu 16.04 - now EOL so trying 18.04
    config.vm.box = "ubuntu/bionic64"

    # Needs plugin vagrant-disksize: `vagrant plugin install vagrant-disksize`
    config.disksize.size = '40GB'

    config.vm.network :forwarded_port, guest: 80, host: 8088    # Django front-end
    config.vm.network :forwarded_port, guest: 8080, host: 8089  # Expt runner

    # This needs to look real enough for git to set a default identity
    config.vm.hostname = "weblab.local"

    config.vm.provider "virtualbox" do |vb|
        vb.name = "WebLab18"
        vb.memory = "4096"
    end

    # Install the Web Lab using Ansible
    config.vm.provision "ansible_local" do |ansible|
        # Install a specific Ansible version with pip
        ansible.install = true
        ansible.install_mode = "pip"
        ansible.pip_install_cmd = "sudo apt-get install -y python-pip"
        ansible.version = "2.8.0"

        ansible.playbook = "site.yml"
        ansible.inventory_path = "inventories/dev"
        ansible.limit = "localhost"
        ansible.raw_arguments = ['--vault-id', 'dev@dev-vault-pw']

        ansible.extra_vars = {
            django_git_branch: 'master',
            celery_git_branch: 'master',
            weblab_fc_branch: 'master',
        }

        ansible.verbose = true
    end
end

