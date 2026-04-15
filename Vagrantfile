Vagrant.configure("2") do |config|
    config.vm.box = "bento/ubuntu-24.04"

    config.vm.define "devops-data" do |data|
        data.vm.hostname = "devops-data"
        data.vm.network "private_network", ip: "192.168.56.14"

        data.vm.provider "virtualbox" do |vb|
            vb.name = "devops-data"
            vb.memory = 1024
            vb.cpus = 2
    
        end
    end

end