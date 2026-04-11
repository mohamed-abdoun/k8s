#!/usr/bin/env python3
"""
Dynamic Ansible inventory that reads config/cluster.yml and emits groups:
  all, masters, workers, lb, etcd (=masters), control_plane (=masters)

Host vars exposed per node:
  node_name, node_ip, node_index, ansible_host, ansible_user,
  ansible_ssh_private_key_file

Cluster-wide vars exposed on the 'all' group:
  cluster_*, network_*, versions_*
"""
import json
import os
import sys
import yaml

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
CONFIG_PATH = os.path.join(REPO_ROOT, 'config', 'cluster.yml')


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def ip_for(subnet: str, last_octet: int) -> str:
    return f"{subnet}.{last_octet}"


def build_inventory(cfg: dict) -> dict:
    net   = cfg['network']
    nodes = cfg['nodes']
    ssh   = cfg['ssh']
    clus  = cfg['cluster']

    subnet          = net['subnet']
    masters_start   = net['masters_first_octet']
    workers_start   = net['workers_first_octet']
    lb_ip           = ip_for(subnet, net['lb_last_octet'])
    master_count    = nodes['masters']['count']
    worker_count    = nodes['workers']['count']

    ssh_key  = os.path.expanduser(ssh['private_key'])
    ssh_user = ssh['user']

    def host_vars(name: str, ip: str, index: int) -> dict:
        return {
            'node_name': name,
            'node_ip':   ip,
            'node_index': index,
            'ansible_host': ip,
            'ansible_user': ssh_user,
            'ansible_ssh_private_key_file': ssh_key,
        }

    hostvars = {}
    masters, workers = [], []

    for i in range(master_count):
        name = f"master-{i+1}"
        ip   = ip_for(subnet, masters_start + i)
        hostvars[name] = host_vars(name, ip, i)
        masters.append(name)

    for i in range(worker_count):
        name = f"worker-{i+1}"
        ip   = ip_for(subnet, workers_start + i)
        hostvars[name] = host_vars(name, ip, i)
        workers.append(name)

    hostvars['lb'] = host_vars('lb', lb_ip, 0)

    # Cluster-wide vars (available as hostvars on the 'all' group via group_vars,
    # but also exposed here for convenience)
    all_vars = {
        'cluster_name':        clus['name'],
        'kubernetes_version':  clus['kubernetes_version'],
        'etcd_version':        clus['etcd_version'],
        'containerd_version':  clus['containerd_version'],
        'cni_plugins_version': clus['cni_plugins_version'],
        'cilium_version':      clus['cilium_version'],
        'lb_ip':               lb_ip,
        'pod_cidr':            net['pod_cidr'],
        'service_cidr':        net['service_cidr'],
        'service_dns_ip':      net['service_dns_ip'],
        'service_api_ip':      net['service_api_ip'],
        'k8s_cluster_name':    net['cluster_name'],
        'master_ips':          [ip_for(subnet, masters_start + i) for i in range(master_count)],
        'worker_ips':          [ip_for(subnet, workers_start + i) for i in range(worker_count)],
        'first_master':        masters[0] if masters else '',
        'first_master_ip':     ip_for(subnet, masters_start),
        'pki_dir':             os.path.join(REPO_ROOT, 'pki'),
    }

    inventory = {
        'all': {
            'hosts': list(hostvars.keys()),
            'vars':  all_vars,
        },
        'masters':       {'hosts': masters},
        'workers':       {'hosts': workers},
        'lb':            {'hosts': ['lb']},
        'etcd':          {'hosts': masters},
        'control_plane': {'hosts': masters},
        '_meta': {'hostvars': hostvars},
    }
    return inventory


def main():
    cfg       = load_config()
    inventory = build_inventory(cfg)

    if '--list' in sys.argv:
        print(json.dumps(inventory, indent=2))
    elif '--host' in sys.argv and len(sys.argv) > 2:
        host = sys.argv[sys.argv.index('--host') + 1]
        print(json.dumps(inventory['_meta']['hostvars'].get(host, {}), indent=2))
    else:
        print(json.dumps(inventory, indent=2))


if __name__ == '__main__':
    main()
