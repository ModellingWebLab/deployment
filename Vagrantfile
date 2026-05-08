# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

    # We need Ubuntu 18.04
    config.vm.box = "ubuntu/bionic64"

    # Needs plugin vagrant-disksize: `vagrant plugin install vagrant-disksize`
    config.disksize.size = '100GB'

    # NOTE: This will enable public access to the opened ports.
    config.vm.network "forwarded_port", guest: 80, host: 8088    # Django front-end
    config.vm.network "forwarded_port", guest: 8080, host: 8089  # Experiment runner

    # NOTE: This restricts access to the opened ports via 127.0.0.1 only.
    # config.vm.network "forwarded_port", guest: 80, host: 8088, host_ip: "127.0.0.1"
    # config.vm.network "forwarded_port", guest: 8080, host: 8089, host_ip: "127.0.0.1"

    # This needs to look real enough for git to set a default identity
    config.vm.hostname = "weblab.local"

    # Provider-specific configuration for VirtualBox
    config.vm.provider "virtualbox" do |vb|
        vb.name = "WebLab18"
        vb.memory = "4096"
        vb.cpus = "4"
    end

    # Install the Web Lab using Ansible
    config.vm.provision "ansible_local" do |ansible|
        ansible.compatibility_mode = "2.0"
        ansible.install = true

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
