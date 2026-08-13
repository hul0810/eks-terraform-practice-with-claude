################################################################################
# Security Groups for Pods — 노드 SG가 얽히는 규칙
#
# Pod SG 자체는 이 root가 아니라 shared/pods-sg가 소유한다. 그 root는 teardown 대상이 아니어서
# SG ID가 고정되고, devops-manifest의 SecurityGroupPolicy가 그 값을 안정적으로 참조할 수 있다.
#
# 여기 남는 것은 **출발지나 대상이 노드 SG인 규칙**뿐이다. 노드 SG는 클러스터 소유라
# pods-sg에서 참조하면 그 root가 클러스터 lifecycle에 묶여 존재 이유가 사라진다.
# 클러스터가 있을 때만 의미가 있는 규칙이므로 클러스터와 함께 나고 지는 것이 맞다.
#
# [enforcing mode = standard] Pod SG와 노드 SG가 함께 평가되므로, 노드 SG에 이미 있는 규칙
# (kubelet probe, 컨트롤 플레인 통신 등)이 그대로 살아 있다. 그래서 여기 필요한 것은 DNS 하나뿐이다.
# strict로 올리면 노드 SG가 평가에서 빠져 probe 인바운드(포트 <- 노드 SG)를 추가해야 한다.
# 상세: docs/security-groups-for-pods.md
################################################################################

# ── DNS: Pod -> CoreDNS ───────────────────────────────────────────────────────
#
# CoreDNS는 노드 ENI를 쓰는데, 노드 SG의 53 인바운드는 업스트림 모듈이 만드는 self 규칙
# (출발지 = 노드 SG)뿐이라 Pod SG를 달고 온 트래픽이 매칭되지 않는다 — 이 규칙이 없으면
# 이름 해석이 실패한다. SGP를 안 쓰는 Pod는 노드 ENI로 나가 self 규칙에 걸리므로 드러나지 않는다.
#
# standard에서도 필요하다. 노드 SG가 함께 평가된다는 것은 "Pod의 트래픽이 노드 SG 규칙도
# 만족해야 한다"는 뜻이지, 목적지가 Pod를 노드로 인식한다는 뜻이 아니다 — 출발지 신원은 여전히
# 브랜치 ENI의 Pod SG다.
#
# 53으로 한정한다. 노드 SG는 클러스터 전체 노드에 붙으므로 넓게 열면 SGP Pod가 kubelet(10250) 등
# 노드의 다른 포트에도 닿게 되어, 격리하려고 도입한 것이 반대로 구멍이 된다.
# Pod SG가 pods-sg로 분리되면서 for_each 키가 프로토콜 단독("tcp")에서 SG 키를 포함한
# 형태("rds_access.tcp")로 바뀌었다. moved 블록이 없으면 기존 규칙이 destroy 후 recreate되어
# 그 사이 DNS가 끊긴다.
moved {
  from = aws_vpc_security_group_ingress_rule.node_dns_from_pod_sg["tcp"]
  to   = aws_vpc_security_group_ingress_rule.node_dns_from_pod_sg["rds_access.tcp"]
}

moved {
  from = aws_vpc_security_group_ingress_rule.node_dns_from_pod_sg["udp"]
  to   = aws_vpc_security_group_ingress_rule.node_dns_from_pod_sg["rds_access.udp"]
}

resource "aws_vpc_security_group_ingress_rule" "node_dns_from_pod_sg" {
  for_each = {
    for pair in setproduct(keys(local.pod_security_group_ids), ["tcp", "udp"]) :
    "${pair[0]}.${pair[1]}" => { sg_key = pair[0], protocol = pair[1] }
  }

  security_group_id            = local.node_security_group_id
  description                  = "CoreDNS lookup from SGP-enabled pods (${each.value.protocol})"
  referenced_security_group_id = local.pod_security_group_ids[each.value.sg_key]
  from_port                    = 53
  to_port                      = 53
  ip_protocol                  = each.value.protocol

  tags = {
    Name = "${local.cluster_name}-node-dns-from-${each.key}"
  }
}
