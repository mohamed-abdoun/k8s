#cloud-config
hostname: ${hostname}
fqdn: ${hostname}
manage_etc_hosts: false

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ${ssh_public_key}

chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: "$6$JyE7QG.czvpfSAVt$10Z.bkYTTJdt.OL9bEyfenn4v6QZY/IjTk6zM7IUvIFZysFIR4axSYYZtbmussmnZ4586hVMGJ.KD8oT7E1Uz."
      type: hash

packages:
  - python3
  - python3-apt
  - curl
  - wget
  - tar
  - openssl
  - vim
  - qemu-guest-agent

package_update: true

write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      127.0.1.1 ${hostname}
      ${indent(6, hosts_entries)}
    append: false

runcmd:
  - systemctl disable --now ufw || true
  - sed -i 's/^#\?\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart ssh
  - systemctl enable --now qemu-guest-agent
