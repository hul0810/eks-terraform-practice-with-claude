################################################################################
# Route53 크로스 계정 위임 IAM Role
#
# monitoring 계정의 ExternalDNS가 workload 계정 Route53(pyhtest.com)에 DNS 레코드를
# 생성할 수 있도록 크로스 계정 위임 Role을 생성한다.
#
# 동작 원리:
#   1. monitoring 클러스터의 ExternalDNS Pod가 자신의 IRSA Role로 sts:AssumeRole 호출
#   2. 이 Role을 assume → workload 계정 자격증명 획득
#   3. 해당 자격증명으로 pyhtest.com zone에 A/CNAME 레코드 생성·삭제
#
# ExternalDNS Helm chart 설정: --aws-assume-role 플래그로 이 Role ARN을 전달한다
# 주의: --aws-assume-role-arn은 존재하지 않는 플래그 — 혼동 시 Pod가 CrashLoopBackOff에 빠진다
# (monitoring eks-addons에서 external_dns_assume_role_arn 변수로 주입)
################################################################################

resource "aws_iam_role" "route53_delegation" {
  name = "${local.project}-route53-delegation"
  # IAM Role description은 AWS 정규식 제약(ASCII/Latin-1)으로 한글을 허용하지 않아 영문으로 작성
  description = "Cross-account delegation role allowing monitoring account ExternalDNS to manage the pyhtest.com zone"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowMonitoringExternalDNS"
        Effect = "Allow"
        Principal = {
          # monitoring 계정의 ExternalDNS IRSA Role만 AssumeRole 허용 (최소 권한 원칙)
          AWS = local.external_dns_irsa_arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  lifecycle {
    # 삭제 시 monitoring ExternalDNS의 Route53 접근이 즉시 차단됨 — 사전 마이그레이션 필수
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "route53_zone_management" {
  name = "route53-zone-management"
  role = aws_iam_role.route53_delegation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ChangeRecordsInZone"
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        # pyhtest.com zone으로 범위 최소화 — 다른 zone 접근 차단
        Resource = "arn:aws:route53:::hostedzone/${local.route53_zone_id}"
      },
      {
        # ExternalDNS가 zone 목록 탐색 및 레코드 변경 완료 상태 확인에 사용
        Sid    = "ListZonesAndGetChange"
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:GetChange",
        ]
        Resource = "*"
      }
    ]
  })
}
