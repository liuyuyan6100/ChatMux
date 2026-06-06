#!/bin/bash
# ChatMux 上游同步脚本
# 用法: bash scripts/sync-upstream.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1. 拉取上游最新 ==="
git fetch upstream main

echo ""
echo "=== 2. 更新 main (干净分支) ==="
git checkout main
git merge upstream/main --ff-only
git push origin main

echo ""
echo "=== 3. 变基 develop (开发分支) ==="
git checkout develop
if git rebase main; then
    echo "rebase 成功"
else
    echo "!!! 有冲突，手动解决后: git rebase --continue !!!"
    exit 1
fi
git push origin develop --force-with-lease

echo ""
echo "=== 4. 重新构建部署 ==="
docker compose --env-file deploy/web/.env -f deploy/web/docker-compose.yml up -d --build

echo ""
echo "=== 完成 ==="
echo "main (干净):    $(git log main --oneline -1)"
echo "develop (本地): $(git log develop --oneline -1)"
