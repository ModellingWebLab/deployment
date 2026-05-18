# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|

    # We need Ubuntu 18.04
    config.vm.box = "ubuntu/bionic64"

    # Needs plugin vagrant-disksize: `vagrant plugin install vagrant-disksize`
    config.disksize.size = "100GB"

    config.vm.network "private_network", type: "dhcp"

    # NOTE: This will enable public access to the opened ports.
    # Vagrant cannot forward to host ports < 1024
    config.vm.network "forwarded_port", guest: 80, host: 8088    # Django front-end
    #config.vm.network "forwarded_port", guest: 8080, host: 8089  # Don't expose experiment runner

    config.vm.network "forwarded_port", guest: 443, host: 8443  # https for Django front-end

    # NOTE: This restricts access to the opened ports via 127.0.0.1 only.
    # config.vm.network "forwarded_port", guest: 80, host: 8088, host_ip: "127.0.0.1"
    # config.vm.network "forwarded_port", guest: 8080, host: 8089, host_ip: "127.0.0.1"

    config.vm.network "forwarded_port", guest: 22, host: 2222, id: "ssh", host_ip: "127.0.0.1"

    # This needs to look real enough for git to set a default identity
    config.vm.hostname = "weblab.vagrant.local"

    # Make default SSH configuration more secure
    config.ssh.insert_key = true
    # config.ssh.username = "weblabsupport" #(if changing default user, add this after provisioning)

    # config.vm.synced_folder ".", "/vagrant", disabled: true #(uncomment this after provisioning)

    # Provider-specific configuration for VirtualBox
    config.vm.provider "virtualbox" do |vb|
        vb.name = "WebLab23"
        vb.memory = "8192"
        vb.cpus = "8"
    end

    # Install the Web Lab using Ansible
    config.vm.provision "ansible_local" do |ansible|
        ansible.compatibility_mode = "2.0"
        ansible.install = true

        ansible.playbook = "site.yml"
        ansible.inventory_path = "inventories/production"
        ansible.limit = "localhost"
        ansible.raw_arguments = ['--vault-id', 'main@vault-main']

        ansible.extra_vars = {
            django_git_branch: 'master',
            celery_git_branch: 'master',
            weblab_fc_branch: 'master',
        }

        ansible.verbose = true
    end
end
