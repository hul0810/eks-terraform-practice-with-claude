#!/bin/bash
# PostToolUse 훅: prd .tf 파일 변경 시 마커 파일 생성
# stdin: {"tool_name": "Edit", "tool_input": {"file_path": "..."}, ...}

input_json=$(cat)

tool_name=$(echo "$input_json" | jq -r '.tool_name // empty')

# Edit, Write, MultiEdit 도구만 처리
if [[ "$tool_name" != "Edit" && "$tool_name" != "Write" && "$tool_name" != "MultiEdit" ]]; then
  exit 0
fi

file_path=$(echo "$input_json" | jq -r '.tool_input.file_path // empty')
[[ -z "$file_path" ]] && exit 0

# 백슬래시를 슬래시로 정규화
normalized_path="${file_path//\\//}"

# prd .tf 파일 여부 확인
if [[ "$normalized_path" != *"environments/production/"* ]] || [[ "$normalized_path" != *.tf ]]; then
  exit 0
fi

# 스크립트 위치 기준으로 .claude/ 디렉토리 계산
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="$(dirname "$script_dir")"
marker_file="$claude_dir/.prd-changed"

timestamp=$(date "+%Y-%m-%d %H:%M:%S")

if [[ -f "$marker_file" ]]; then
  echo "$file_path" >> "$marker_file"
else
  printf "# prd 변경 감지: %s\n%s\n" "$timestamp" "$file_path" > "$marker_file"
fi

exit 0
