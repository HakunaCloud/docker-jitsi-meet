variable "do_token" {}
variable "region" { default = "fra1" }
variable "ssh_key" { }
variable "n_host" { default = 2 }

variable "zt_network_management" { }
variable "zt_api_token" { }
variable "salt_autotoken" { }



provider "digitalocean" {
  token = var.do_token
}

provider "aws" {
  profile = "hakuna"
  region = "eu-west-1"
}

resource "digitalocean_droplet" "jitsi" {
  count = var.n_host
  image = "ubuntu-18-04-x64"
  name = "cov-jitsi-${count.index}"
  region = var.region
  size = "s-12vcpu-48gb"
  backups = false
  monitoring = true
  private_networking = false
  ssh_keys = [var.ssh_key]
  tags = ["jits", "covid"]
  user_data = <<-EOF
      #!/bin/bash -x
      apt-get update
      apt-get install -y vim jq awscli ntp

      export TAG_NAME=$(hostname)
      ##############
      ## ZeroTier ##
      ##############
      curl -s https://install.zerotier.com | sudo bash

      export NODEID=$(zerotier-cli -j info | jq .address -r)

      # pre-autorize the node
      curl "https://my.zerotier.com/api/network/${var.zt_network_management}/member/$NODEID" \
        -X POST \
        -H "Authorization: bearer ${var.zt_api_token}" \
        -H "Content-Type: application/json" \
        --data-binary '{"config":{"authorized":true}}'

      # Join the network
      zerotier-cli join ${var.zt_network_management}

      # Set the node name
      curl "https://my.zerotier.com/api/network/${var.zt_network_management}/member/$NODEID" \
          -X POST \
          -H "Authorization: bearer ${var.zt_api_token}" \
          -H "Content-Type: application/json" \
          --data-binary "{\"name\":\"$TAG_NAME\", \"config\":{}}"

      # Wait for an ip. It may take more than 5 seconds
      MY_IP=$(ifconfig | grep 172.22 | awk '{print $2}')
      retries=20
      while [[ -z $MY_IP ]]
          do
              if (( retries-- == 0 ))
                  then echo >&2 'ERROR Never got an ip'
                  exit 1
              fi
              echo "Waiting for ZeroTier ip...."
              sleep 2
              MY_IP=$(ifconfig | grep 172.22 | awk '{print $2}')
              echo "got [$MY_IP]"
      done

      MY_IP=$(ifconfig | grep 172.22 | awk '{print $2}')

      ########################
      # Network Restrictions #
      ########################
      echo "ListenAddress $MY_IP" >> /etc/ssh/sshd_config
      systemctl restart sshd

      #############
      # SaltStack #
      #############
      curl -o bootstrap-salt.sh -L https://bootstrap.saltstack.com
      sh bootstrap-salt.sh git develop

      echo "autotoken: ${var.salt_autotoken} " >> /etc/salt/grains
      echo "az: ${element(["fra1", "ams3"], count.index )} " >> /etc/salt/grains
      echo "region: eu-west-1" >> /etc/salt/grains
      echo "family: jitsi" >> /etc/salt/grains
      echo "provider: digitalocean" >> /etc/salt/grains
      echo "stage: prod" >> /etc/salt/grains

      # minion use socket.gwtfqdn() that returns the AWS dns name maybe because it does a reverse lookup on the ip address?
      # forcing here the hostname to match the minion id
      echo "id: $TAG_NAME" >> /etc/salt/minion
      echo "master: salt.zt.hakunacloud.com" >> /etc/salt/minion
      echo "minion_id_caching: False" >> /etc/salt/minion
      echo "grains_refresh_every: 1" >> /etc/salt/minion

      # Autoaccept this guy
      echo "autosign_grains: " >> /etc/salt/minion
      echo "    - autotoken " >> /etc/salt/minion

      systemctl restart salt-minion.service

      sleep 5
      salt-call state.highstate

      EOF
}

resource "digitalocean_firewall" "web" {
  name = "covid-jitsi-public"

  droplet_ids = digitalocean_droplet.jitsi.*.id

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["2.236.103.86/32"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "udp"
    port_range       = "9993"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

}

resource "digitalocean_floating_ip" "factotum_ip" {
  count = var.n_host
  region = var.region
}

resource "digitalocean_floating_ip_assignment" "daje" {
  count = var.n_host
  droplet_id = digitalocean_droplet.jitsi[count.index].id
  ip_address = digitalocean_floating_ip.factotum_ip[count.index].ip_address
}

resource "aws_route53_record" "factotum_dns" {
  zone_id = "Z375RUNQIKSVJO"  # hakunacloud.com
  count = var.n_host
  name    = "jitsi-${count.index}.iorestoacasa.hakunacloud.com"
  ttl     = "300"
  type    = "A"

  records = [digitalocean_floating_ip.factotum_ip[count.index].ip_address]
}

output "jitsi_eip" {
  value = digitalocean_floating_ip.factotum_ip.*.ip_address
}

output "instances" {
  value = digitalocean_droplet.jitsi.*.name
}
