#!/bin/bash
# PreToolUse 훅: project/environments/production/ 에서 terraform apply 강제 차단
# stdin: {"tool_name": "Bash", "tool_input": {"command": "..."}, ...}

input_json=$(cat)

tool_name=$(echo "$input_json" | jq -r '.tool_name // empty')

# Bash 도구만 처리
[[ "$tool_name" != "Bash" ]] && exit 0

command=$(echo "$input_json" | jq -r '.tool_input.command // empty')
[[ -z "$command" ]] && exit 0

# terraform apply 감지 (apply 단독, -auto-approve, -var 등 모든 형태 포함)
if ! echo "$command" | grep -qE '\bterraform\b.*\bapply\b'; then
  exit 0
fi

# 백슬래시를 슬래시로 정규화 (Windows 경로 대응)
normalized="${command//\\//}"

# environments/production/ 경로 감지
if echo "$normalized" | grep -q "environments/production"; then
  cat >&2 <<'EOF'
╔═══════════════════════════════════════════════════════════╗
║      [BLOCKED] production terraform apply 차단됨           ║
╚═══════════════════════════════════════════════════════════╝

environments/production/ 에서 terraform apply는
Claude가 직접 실행할 수 없습니다.

올바른 배포 절차:
  1. /review-terraform 스킬로 코드 리뷰 완료
  2. PR 생성 및 팀 검토·승인
  3. 터미널에서 사용자가 직접 실행:
       cd project/environments/production/<region>/<project>/<resource>/
       terraform apply

EOF
  exit 2
fi

exit 0
