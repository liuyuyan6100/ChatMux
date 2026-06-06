#!/bin/bash
# ChatMux 上游同步脚本
# 用法: bash scripts/update-upstream.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1. 拉取上游最新 ==="
git fetch upstream main

echo ""
echo "=== 2. 更新本地 main ==="
git checkout main
git merge upstream/main --ff-only

echo ""
echo "=== 3. 变基本地定制分支 ==="
git checkout local-custom
if git rebase main; then
    echo "rebase 成功，无冲突"
else
    echo "!!! 有冲突，需要手动解决 !!!"
    echo "  git status        # 查看冲突文件"
    echo "  git add <file>    # 解决后标记"
    echo "  git rebase --continue"
    echo "  或: git rebase --abort 放弃"
    exit 1
fi

echo ""
echo "=== 4. 重新构建部署 ==="
git checkout local-custom
docker compose --env-file deploy/web/.env -f deploy/web/docker-compose.yml up -d --build

echo ""
echo "=== 完成 ==="
echo "当前分支: $(git branch --show-current)"
echo "上游版本: $(git log main --oneline -1)"
echo "本地版本: $(git log local-custom --oneline -1)"
