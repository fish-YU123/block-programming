#!/bin/sh
# 开工前同步：把远程 main 拉到本地（线性 rebase，历史干净）。
#
#   ./tools/sync.sh            # 有本地改动会先 stash，拉完再恢复
#   ./tools/sync.sh --check    # 只看差多少，不动工作区
#
set -e
cd "$(dirname "$0")/.." || exit 1

if [ "$1" = "--check" ]; then
	git fetch origin --prune
	git log --oneline HEAD..origin/main
	echo "---- 本地领先 ----"
	git log --oneline origin/main..HEAD
	exit 0
fi

git fetch origin --prune
stashed=0
if [ -n "$(git status --porcelain)" ]; then
	echo "本地有未提交改动，先 stash…"
	git stash push -u -m "sync-$(date +%Y%m%d-%H%M%S)"
	stashed=1
fi
git pull --rebase origin main
if [ "$stashed" = "1" ]; then
	if git stash pop; then
		echo "改动已恢复"
	else
		echo "⚠️ stash 恢复有冲突，用 git stash list / git status 处理" >&2
		exit 1
	fi
fi
echo "---- 最近提交 ----"
git log --oneline -3
echo "---- 工作区 ----"
git status --short || true
