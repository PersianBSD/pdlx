#!/bin/bash
set -e

# مسیر مخزن
REPO_DIR="/home/$USER/pdlx-v1/x86_64"

REPO_NAME="pdlx-v1"

cd "$REPO_DIR" || { echo "❌ Cannot access $REPO_DIR"; exit 1; }

# حذف دیتابیس قدیمی
rm -f "${REPO_NAME}.db" "${REPO_NAME}.files"

# ایجاد دیتابیس جدید
repo-add "${REPO_NAME}.db.tar.zst" ./*.pkg.tar.zst

echo "✅ $REPO_NAME Repo updated succesfully "
