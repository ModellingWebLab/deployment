# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

    # We need Ubuntu 16.04
    config.vm.box = "ubuntu/xenial64"

    config.vm.network :forwarded_port, guest: 80, host: 8088    # Django front-end
    config.vm.network :forwarded_port, guest: 8080, host: 8089  # Expt runner

    config.vm.provider "virtualbox" do |vb|
        vb.name = "WebLab"
        vb.memory = "4096"
    end

    # Install the Web Lab using Ansible
    config.vm.provision "ansible_local" do |ansible|
        # Install a specific Ansible version with pip
        ansible.install = true
        ansible.install_mode = "pip"
        ansible.version = "2.5.0"

        ansible.playbook = "site.yml"
        ansible.inventory_path = "dev"
        ansible.limit = "localhost"
        ansible.raw_arguments = ['--vault-id', 'dev@dev-vault-pw']

        ansible.extra_vars = {
            django_git_branch: 'master'
        }

        ansible.verbose = true
    end
end

