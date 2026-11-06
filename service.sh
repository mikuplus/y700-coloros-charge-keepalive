#!/system/bin/sh
# supervisor：拉起并监控 worker.sh，自身永不退出。
# 两道保险：
#   1) 启动前 `sh -n` 语法检查，语法错就直接从 worker.sh.bak 回滚
#   2) 运行期若 5 秒内就退出，连续 3 次判定为坏版本，自动回滚
# 正常运行满 30 秒会把当前版本存为 worker.sh.bak（已知良好版本）。

MODDIR=${0%/*}
LOG=/data/local/tmp/charge_keepalive.log
WORKER="$MODDIR/worker.sh"
BAK="$MODDIR/worker.sh.bak"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

hash_of() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
  else
    stat -c '%Y-%s' "$1" 2>/dev/null
  fi
}

syntax_ok() {
  [ -f "$1" ] && sh -n "$1" 2>/dev/null
}

# worker 拔电时会阻塞在 logcat 上；kill worker 后它变孤儿，主动清掉
cleanup_children() {
  pkill -f 'logcat -b events -T' 2>/dev/null
  return 0
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 3; done
sleep 5

if [ -f "$LOG" ]; then
  SZ=$(wc -c < "$LOG" 2>/dev/null)
  [ -n "$SZ" ] && [ "$SZ" -gt 262144 ] && mv -f "$LOG" "$LOG.old"
fi

log "===== supervisor 启动 pid=$$ （含语法检查/自动回滚）====="

FASTFAIL=0

while true; do
  if [ ! -f "$WORKER" ]; then
    log "worker.sh 不存在，等待"
    sleep 5
    continue
  fi

  # ---- 保险 1：语法检查 ----
  if ! syntax_ok "$WORKER"; then
    ERR=$(sh -n "$WORKER" 2>&1 | head -2 | tr '\n' ' ')
    log "!! worker.sh 语法错误：$ERR"
    if syntax_ok "$BAK"; then
      cp -f "$BAK" "$WORKER"
      log "已从 worker.sh.bak 回滚"
      FASTFAIL=0
      sleep 1
      continue
    else
      log "无可用备份，10 秒后重试"
      sleep 10
      continue
    fi
  fi

  H=$(hash_of "$WORKER")
  START=$(date +%s)
  log "拉起 worker (hash=$H)"
  sh "$WORKER" &
  WPID=$!

  RELOAD=0
  BAK_OK=0
  while kill -0 "$WPID" 2>/dev/null; do
    sleep 2
    NH=$(hash_of "$WORKER")
    if [ "$NH" != "$H" ]; then
      log "检测到 worker.sh 变更 ($H -> $NH)，重载"
      RELOAD=1
      kill "$WPID" 2>/dev/null
      sleep 1
      kill -9 "$WPID" 2>/dev/null
      cleanup_children
      break
    fi
    # 跑满 30 秒仍存活且文件未被改动 → 认定这份是好的。
    # 必须在运行期就存，不能等 worker 退出：worker 是常驻进程，
    # 正常情况永远不退出，等退出再存等于永远不存。
    if [ "$BAK_OK" = "0" ] && [ $(( $(date +%s) - START )) -ge 30 ]; then
      if cp -f "$WORKER" "$BAK" 2>/dev/null; then
        BAK_OK=1
        log "worker 稳定运行 30s，已更新回滚备份"
      fi
    fi
  done

  cleanup_children
  END=$(date +%s)
  DUR=$((END - START))

  if [ "$RELOAD" = "1" ]; then
    sleep 1
    continue
  fi

  # ---- 保险 2：快速失败检测 ----
  if [ "$DUR" -lt 5 ]; then
    FASTFAIL=$((FASTFAIL+1))
    log "!! worker 异常退出（运行 ${DUR}s），连续失败 ${FASTFAIL}/3"
    if [ "$FASTFAIL" -ge 3 ]; then
      if syntax_ok "$BAK"; then
        cp -f "$BAK" "$WORKER"
        log "连续失败 3 次，已从 worker.sh.bak 回滚"
        FASTFAIL=0
        sleep 2
        continue
      else
        log "连续失败且无可用备份，暂停 30 秒"
        sleep 30
        FASTFAIL=0
      fi
    fi
  else
    # 备份已在上面的监控循环里、跑满 30 秒时就存好了，这里只需清掉失败计数
    FASTFAIL=0
  fi

  sleep 1
done
