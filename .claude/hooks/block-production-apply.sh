#!/bin/bash
# PreToolUse 훅: project/environments/production/ 에서 terraform apply 강제 차단
# stdin: {"tool_name": "Bash", "cwd": "...", "tool_input": {"command": "..."}, ...}

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

cwd=$(echo "$input_json" | jq -r '.cwd // empty')

# 백슬래시를 슬래시로 정규화 (Windows 경로 대응)
normalized_command="${command//\\//}"
normalized_cwd="${cwd//\\//}"

# environments/production/ 경로 감지
# command 문자열뿐 아니라 cwd도 검사한다: 이미 production 디렉토리로 cd한 상태에서
# 경로 없이 "terraform apply"만 실행하면 command 문자열만으로는 탐지되지 않기 때문이다.
if echo "$normalized_command" | grep -q "environments/production" || echo "$normalized_cwd" | grep -q "environments/production"; then
  cat >&2 <<'EOF'
╔═══════════════════════════════════════════════════════════╗
║      [BLOCKED] production terraform apply 차단됨           ║
╚═══════════════════════════════════════════════════════════╝

environments/production/ 에서 terraform apply는
Claude가 직접 실행할 수 없습니다.

올바른 배포 절차:
  1. /git-commit 실행 (Step 4에서 /review-terraform 자동 실행)
  2. PR 생성 및 팀 검토·승인
  3. 터미널에서 사용자가 직접 실행:
       cd project/environments/production/<region>/<project>/<resource>/
       terraform apply

EOF
  exit 2
fi

exit 0
