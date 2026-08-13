output "pod_security_group_ids" {
  description = "SGP Pod SG ID 맵(키 = pod_security_groups의 키). eks-addons가 probe·DNS 규칙의 참조원으로, rds가 RDS SG inbound의 출발지로 사용한다"
  value       = { for k, sg in aws_security_group.pod : k => sg.id }
}

output "pod_security_group_probe_ports" {
  description = "SG별 kubelet probe 포트 맵. 규칙은 eks-addons가 만든다 — 출발지가 노드 SG라 이 root가 참조하면 클러스터 lifecycle에 묶인다"
  value       = { for k, sg in local.pod_security_groups : k => sg.probe_ports }
}

output "pod_rds_access_security_group_id" {
  description = "RDS 접근용 Pod SG ID. devops-manifest의 SecurityGroupPolicy CR이 참조하는 값이며, 이 root는 teardown 대상이 아니라 ID가 고정된다"
  value       = aws_security_group.pod["rds_access"].id
}
