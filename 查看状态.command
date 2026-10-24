#!/bin/bash
set -u
sudo '/Library/Application Support/SurgeDisconnectGuard/sgctl' status
RESULT=$?
read -r -p '按回车关闭窗口…' _
exit "$RESULT"
