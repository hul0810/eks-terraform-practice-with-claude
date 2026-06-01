#!/bin/bash
# Stop 훅: prd 변경 마커가 있으면 리뷰를 강제하고 Claude 작업을 계속하도록 지시

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="$(dirname "$script_dir")"
marker_file="$claude_dir/.prd-changed"

[[ ! -f "$marker_file" ]] && exit 0

changed=$(cat "$marker_file")

cat >&2 <<EOF
[production 리뷰 게이트] project/environments/production/ 파일 변경이 감지되었습니다.

$changed

작업 완료 전 /review-terraform 스킬을 실행하여
terraform-reviewer + aws-architect 리뷰를 완료해야 합니다.
EOF

exit 2
