output "lb_ip" {
  value = local.lb_ip
}

output "master_ips" {
  value = { for m in local.masters : m.name => m.ip }
}

output "worker_ips" {
  value = { for w in local.workers : w.name => w.ip }
}
