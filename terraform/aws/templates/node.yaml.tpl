#cloud-config

---
write_files:
  - path: /etc/inventory.ansible
    content: |
      [nodes]
      ${short_name} ansible_ssh_host=$private_ipv4

      [nodes:vars]
      ansible_connection=ssh
      ansible_python_interpreter="PATH=/home/core/bin:$PATH python"
      ansible_ssh_user=core
      ansible_ssh_private_key_file=/opt/ansible/private_key
      cluster_master_record=${cluster_master_record}
      cluster_proxy_record=${cluster_proxy_record}
      cluster_name=${cluster_name}
      dns_domain=${dns_domain}
      dns_ip=${dns_ip}
      dockercfg_base64=${dockercfg_base64}
      etcd_private_ip=${etcd_private_ip}
      etcd_public_ip=${etcd_public_ip}
      hyperkube_deployment_mode=${hyperkube_deployment_mode}
      hyperkube_image=${hyperkube_image}
      interface_name=${interface_name}
      kraken_services_branch=${kraken_services_branch}
      kraken_services_dirs=${kraken_services_dirs}
      kraken_services_repo=${kraken_services_repo}
      kubernetes_api_version=${kubernetes_api_version}
      kubernetes_binaries_uri=${kubernetes_binaries_uri}
      logentries_token=${logentries_token}
      logentries_url=${logentries_url}
      master_private_ip=${master_private_ip}
      master_public_ip=${master_public_ip}
  - path: "/etc/rkt/net.d/10-containernet.conf"
    permissions: "0644"
    owner: "root"
    content: |
      {
        "name": "containernet",
        "type": "flannel"
      }
coreos:
  etcd2:
    proxy: on
    listen-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    advertise-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    initial-cluster: etcd=http://${etcd_private_ip}:2380
  fleet:
    etcd-servers: http://$private_ipv4:4001
    public-ip: $private_ipv4
    metadata: "role=node"
  flannel:
    etcd-endpoints: http://${etcd_private_ip}:4001
    interface: $private_ipv4
  units:
    - name: change-rkt-version.service
      command: start
      content: |
        [Unit]
        Description=Add Alternate rkt Version
        Before=format-storage.service

        [Service]
        ExecStartPre=-/usr/bin/mkdir -p /opt/bin
        ExecStartPre=/usr/bin/wget -N -P /opt/bin https://github.com/coreos/rkt/releases/download/v0.8.1/rkt-v0.8.1.tar.gz
        ExecStartPre=/usr/bin/tar -xvzf /opt/bin/rkt-v0.8.1.tar.gz --directory /opt/bin
        ExecStart=/opt/bin/rkt-v0.8.1/rkt version
        RemainAfterExit=yes
        Type=oneshot
    - name: format-storage.service
      command: start
      content: |
        [Unit]
        Description=Formats a drive
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/wipefs -f ${format_docker_storage_mnt}
        ExecStart=/usr/sbin/wipefs -f ${format_kubelet_storage_mnt}
        ExecStart=/usr/sbin/mkfs.ext4 -F ${format_docker_storage_mnt}
        ExecStart=/usr/sbin/mkfs.ext4 -F ${format_kubelet_storage_mnt}
    - name: docker.service
      mask: yes
    - name: var-lib-docker.mount
      command: start
      content: |
        [Unit]
        Description=Mount to /var/lib/docker
        Requires=format-storage.service
        After=format-storage.service
        Before=docker.service
        [Mount]
        What=${format_docker_storage_mnt}
        Where=/var/lib/docker
        Type=ext4
    - name: var-lib-kubelet.mount
      command: start
      content: |
        [Unit]
        Description=Mount to /var/lib/docker
        Requires=format-storage.service
        After=format-storage.service
        Before=docker.service
        [Mount]
        What=${format_kubelet_storage_mnt}
        Where=/var/lib/kubelet
        Type=ext4
    - name: setup-network-environment.service
      command: start
      content: |
        [Unit]
        Description=Setup Network Environment
        Documentation=https://github.com/kelseyhightower/setup-network-environment
        Requires=network-online.target
        After=network-online.target
        Before=flanneld.service

        [Service]
        ExecStartPre=-/usr/bin/mkdir -p /opt/bin
        ExecStartPre=/usr/bin/wget -N -P /opt/bin https://github.com/kelseyhightower/setup-network-environment/releases/download/v1.0.0/setup-network-environment
        ExecStartPre=/usr/bin/chmod +x /opt/bin/setup-network-environment
        ExecStart=/opt/bin/setup-network-environment
        RemainAfterExit=yes
        Type=oneshot
    - name: fleet.service
      command: start
    - name: etcd2.service
      command: start
    - name: flanneld.service
      command: start
    - name: systemd-journal-gatewayd.socket
      command: start
      enable: yes
      content: |
        [Unit]
        Description=Journal Gateway Service Socket
        [Socket]
        ListenStream=/var/run/journald.sock
        Service=systemd-journal-gatewayd.service
        [Install]
        WantedBy=sockets.target
    - name: generate-ansible-keys.service
      command: start
      content: |
        [Unit]
        Description=Generates SSH keys for ansible container
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStartPre=-/usr/bin/rm /home/core/.ssh/ansible_rsa*
        ExecStart=/usr/bin/bash -c "ssh-keygen -f /home/core/.ssh/ansible_rsa -N ''"
        ExecStart=/usr/bin/bash -c "cat /home/core/.ssh/ansible_rsa.pub >> /home/core/.ssh/authorized_keys"
    - name: kraken-git-pull.service
      command: start
      content: |
        [Unit]
        Requires=generate-ansible-keys.service
        After=generate-ansible-keys.service
        Description=Fetches kraken repo
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/bin/rm -rf /opt/kraken
        ExecStart=/usr/bin/git clone -b ${kraken_branch} ${kraken_repo} /opt/kraken
    - name: write-sha-file.service
      command: start
      content: |
        [Unit]
        Requires=kraken-git-pull.service
        After=kraken-git-pull.service
        Description=writes optional sha to a file
        [Service]
        Type=oneshot
        ExecStart=/usr/bin/bash -c '/usr/bin/echo "${kraken_commit}" > /opt/kraken/commit.sha'
    - name: fetch-kraken-commit.service
      command: start
      content: |
        [Unit]
        Requires=write-sha-file.service
        After=write-sha-file.service
        Description=fetches an optional commit
        ConditionFileNotEmpty=/opt/kraken/commit.sha
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        WorkingDirectory=/opt/kraken
        ExecStart=/usr/bin/git fetch ${kraken_repo} +refs/pull/*:refs/remotes/origin/pr/*
        ExecStart=/usr/bin/git checkout -f ${kraken_commit}
    - name: ansible-in-rkt.service
      command: start
      content: |
        [Unit]
        Requires=write-sha-file.service
        After=fetch-kraken-commit.service
        Description=Runs a prebaked ansible container
        [Service]
        Type=simple
        Restart=on-failure
        RestartSec=3
        ExecStart=/opt/bin/rkt-v0.8.1/rkt run --insecure-skip-verify --volume /etc/inventory.ansible,kind=host,source=/etc/inventory.ansible --volumne /opt/kraken,kind=host,source=/opt/kraken --volume opt/ansible/private_key,kind=host,source=/home/core/.ssh/ansible_rsa --volume /ansible,kind=host,source=/var/run --set-env=ANSIBLE_HOST_KEY_CHECKING=False docker://${ansible_docker_image} --exec /sbin/my_init -- --skip-startup-files --skip-runit -- ${ansible_playbook_command} ${ansible_playbook_file}
  update:
    group: ${coreos_update_channel}
    reboot-strategy: ${coreos_reboot_strategy}
