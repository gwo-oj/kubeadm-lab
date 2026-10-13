#!/usr/bin/env bash
# 실습 VM을 (기본/HA 구성 상관없이) 전부 삭제한다. 망가졌을 때: ./down.sh -y && ./up.sh
set -euo pipefail

# up.sh 의 ALL_NODES 와 맞출 것
NODES="cp1 cp2 cp3 w1 w2 lb"

if [ "${1:-}" != "-y" ]; then
  printf '실습 VM(%s 중 있는 것)을 삭제합니다. 계속할까요? [y/N] ' "$NODES"
  read -r answer
  case "$answer" in y|Y) ;; *) echo "취소"; exit 0 ;; esac
fi

existing=""
for node in $NODES; do
  multipass info "$node" >/dev/null 2>&1 && existing="$existing $node"
done

if [ -z "$existing" ]; then
  echo "삭제할 VM 없음"
  exit 0
fi

# shellcheck disable=SC2086
multipass delete $existing
multipass purge
echo "삭제 완료:$existing"
