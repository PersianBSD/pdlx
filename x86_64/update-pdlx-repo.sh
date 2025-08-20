#!/bin/bash
set -e

# مسیر مخزن
REPO_DIR="/home/$USER/repo/x86_64"

REPO_NAME="pdlx"

cd "$REPO_DIR" || { echo "❌ Cannot access $REPO_DIR"; exit 1; }

# حذف دیتابیس قدیمی
rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"

# ایجاد دیتابیس جدید
repo-add "${REPO_NAME}.db.tar.zst" ./*.pkg.tar.zst

echo "✅ $REPO_NAME Repo updated succesfully "
