#!/system/bin/sh
# worker：实际逻辑。被 supervisor 拉起，替换本文件即可热重载。
# 可调参数在 config.prop，改完约 3 秒内自动生效。
#
# 只有真正在充电时才 0.3 秒高频工作；没在充电时降到 5 秒一次静默自查。

MODDIR=${0%/*}
BAT=/sys/class/power_supply/battery
USB=/sys/class/power_supply/usb
LOG=/data/local/tmp/charge_keepalive.log
CSV=/data/local/tmp/charge_sessions.csv
CAL_FILE="$MODDIR/cdev_map.cache"
CONF="$MODDIR/config.prop"

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
# 只取开头连续的数字，避免行尾注释里的数字被混进来
numonly() { echo "$1" | sed 's/[^0-9].*//'; }
# 保留小数点的数值（用于 0.3 这类秒数）
numdec() { echo "$1" | sed 's/[^0-9.].*//'; }

# ---------- 默认参数 ----------
ENABLE_CE=1
ENABLE_THERMAL=1
CE_TEMP_MAX=450
CAP_MAX=100
TEMP_6A=390
TEMP_4A=410
TEMP_3A=430
QUIET_6A=44000
QUIET_4A=45000
QUIET_3A=46000
MAX_CURRENT=6000000     # 最低温档目标电流(mA)，自动映射到冷却档位
CHARGE_POLL=0.3         # 充电时多少秒轮询一次
IDLE_POLL=5             # 没在充电时多少秒自查一次
IDLE_NEED=20            # 连续多少次（按 CHARGE_POLL 计）检测到放电才停止轮询
ENABLE_CALIBRATE=1      # 首次插电时自动标定 cooling 档位 → 限流映射
CELLS=2                 # 电芯数：2=串联双芯（Y700 四代），只影响功率统计

# ---- 电量分档限流（保护电池，和温度档取更保守的那个）----
# 锂电池 80% 以上内阻上升、嵌锂变慢，大电流会加剧锂析出（容量永久衰减）。
# 7600mAh 电池 1C≈7.6A：0.79C / 0.66C / 0.39C / 0.2C
ENABLE_SOC_GUARD=1
SOC_80=80
SOC_90=90
SOC_95=95
SOC_A_80=5000000        # 80~89%  上限 5A（约 0.66C）
SOC_A_90=3000000        # 90~94%  上限 3A（约 0.39C）
SOC_A_95=1500000        # >=95%   上限 1.5A（约 0.2C）

# 冷却档位 → 限流 实测映射（Y700 / cooling_device41，max=20）
# cur:  0     2     4     6     8     10    12    13    14    15    16    17    18    19    20
#  A:  13.0  12.5  11.5  10.5   9.5   8.5   7.0   6.0   5.0   4.0   3.0   2.5   2.0   1.5   0.5
CDEV_MAP="0:13000 2:12500 4:11500 6:10500 8:9500 10:8500 12:7000 13:6000 14:5000 15:4000 16:3000 17:2500 18:2000 19:1500 20:500"

# 给目标电流，返回能提供 >= 目标 的最小档位对应的 cur_state
find_cur() {
  T=$1
  BEST_CUR=""
  BEST_A=99999999
  for pair in $CDEV_MAP; do
    c=${pair%%:*}
    a=$(( ${pair##*:} * 1000 ))
    if [ "$a" -ge "$T" ] && [ "$a" -lt "$BEST_A" ]; then
      BEST_A=$a
      BEST_CUR=$c
    fi
  done
  [ -z "$BEST_CUR" ] && BEST_CUR=0
  echo "$BEST_CUR"
}

# 扫描冷却档位，读出每档真实的 charge_control_limit，生成映射表。
# 同一 cur_state 在不同电量/温度下对应的限流并不固定（实测 12 档在 60% 时 7.0A、
# 90% 时 6.5A），所以首次插电标定一次比硬编码更准。约 2 秒。
calibrate_map() {
  local cur lim prev map ok orig
  [ -z "$CDEV" ] && return 1
  orig=$(cat "$CDEV/cur_state" 2>/dev/null)
  log "开始标定冷却档位映射（约 2 秒）..."
  prev=99999999
  ok=1
  map=""
  for cur in 0 2 4 6 8 10 12 13 14 15 16 17 18 19 20; do
    echo "$cur" > "$CDEV/cur_state" 2>/dev/null
    sleep 0.12
    lim=$(numonly "$(cat "$BAT/charge_control_limit" 2>/dev/null)")
    if [ -z "$lim" ]; then ok=0; break; fi
    lim=$(( lim / 1000 ))
    # 必须单调不增（cur 越大限流越小），否则说明被内核温控抢写了
    [ "$lim" -gt "$prev" ] && ok=0
    prev=$lim
    map="$map $cur:$lim"
  done
  [ -n "$orig" ] && echo "$orig" > "$CDEV/cur_state" 2>/dev/null

  if [ "$ok" = "1" ] && [ -n "$map" ]; then
    map=${map# }
    echo "$map" > "$CAL_FILE" 2>/dev/null
    CDEV_MAP="$map"
    log "标定成功: $map"
    return 0
  fi
  log "标定失败（读数缺失或被内核干扰），沿用默认表"
  return 1
}

# ---- 充电会话统计 ----
SESS_ON=0
SESS_T0=0
SESS_CAP0=0
SESS_FIX0=0
SESS_TMAX=0
SESS_WSUM=0
SESS_N=0

sess_begin() {
  SESS_ON=1
  SESS_T0=$(date +%s)
  SESS_CAP0=$(cat "$BAT/capacity" 2>/dev/null); SESS_CAP0=${SESS_CAP0:-0}
  SESS_FIX0=$FIX
  SESS_TMAX=0
  SESS_WSUM=0
  SESS_N=0
}

sess_sample() {
  local ib vb w
  [ "$SESS_ON" = "1" ] || return 0
  ib=$(cat "$BAT/current_now" 2>/dev/null); ib=${ib:-0}
  # 只有真正在充电（电流为负）才计入平均功率，否则放电会把均值拉低
  [ "$ib" -ge 0 ] && return 0
  vb=$(cat "$BAT/voltage_now" 2>/dev/null); vb=${vb:-0}
  ib=${ib#-}
  # 内核报的是单芯电压；串联双芯整包电压 = 单芯 × CELLS
  vb=$(( vb * CELLS ))
  # uA × uV → W
  w=$(( ib * vb / 1000000000000 ))
  SESS_WSUM=$(( SESS_WSUM + w ))
  SESS_N=$(( SESS_N + 1 ))
  [ "$TEMP" -gt "$SESS_TMAX" ] && SESS_TMAX=$TEMP
}

sess_end() {
  local dur cap1 fixn avgw
  [ "$SESS_ON" = "1" ] || return 0
  SESS_ON=0
  dur=$(( $(date +%s) - SESS_T0 ))
  [ "$dur" -lt 60 ] && return 0            # 太短可能是插拔抖动，不记
  cap1=$(cat "$BAT/capacity" 2>/dev/null); cap1=${cap1:-0}
  fixn=$(( FIX - SESS_FIX0 ))
  avgw=0
  [ "$SESS_N" -gt 0 ] && avgw=$(( SESS_WSUM / SESS_N ))

  [ -f "$CSV" ] || echo "date,dur_min,cap_from,cap_to,avg_w,max_temp_0.1C,ce_fixes" > "$CSV"
  echo "$(date '+%m-%d %H:%M'),$(( dur / 60 )),${SESS_CAP0}%,${cap1}%,${avgw},${SESS_TMAX},${fixn}" >> "$CSV"
  log "会话结束: ${dur}s ${SESS_CAP0}%→${cap1}% 均${avgw}W 峰温${SESS_TMAX} 修复${fixn}次"

  # 防止无限增长
  if [ "$(wc -l < "$CSV" 2>/dev/null)" -gt 200 ]; then
    tail -120 "$CSV" > "$CSV.tmp" 2>/dev/null && mv -f "$CSV.tmp" "$CSV"
  fi
}

# 判断「是否真的在充电」，即是否需要保活。
# 返回 0 = 需要保活；返回 1 = 不需要（进入阻塞等待）
# 注意：充电刚建立时电流会短暂为正，不能一次就判死，放电必须连续 IDLE_NEED 次才算。
need_keepalive() {
  local CE T ST IB CAP
  # 没接任何电源
  if [ "$(cat "$USB/online" 2>/dev/null)" != "1" ]; then
    IDLE_CNT=0
    return 1
  fi
  # 只接电脑 USB（CDP/SDP）供电不足，不算真充电。
  # 必须放在 ce=0 判定之前：这种口上内核会周期性把 ce 写成 0，
  # 若先判 ce=0 就会每 10 秒被误判成"需要保活"，来回空转。
  T=$(cat "$USB/type" 2>/dev/null)
  case "$T" in
    USB_CDP|USB_SDP) IDLE_CNT=0; return 1;;
  esac
  # 满电（status 可能是 Full，也可能直接变 Not charging，两者都要挡）。
  # 必须放在 ce=0 之前：满电时内核会主动把 ce 置 0，若先判 ce=0 会被误判成"需要保活"。
  ST=$(cat "$BAT/status" 2>/dev/null)
  if [ "$ST" = "Full" ]; then
    IDLE_CNT=0
    return 1
  fi
  # 电量已到上限（CAP_MAX，默认 100）——保活逻辑此时本来也不会写 ce，
  # 但循环仍会 0.3 秒跑，必须一并停掉
  CAP=$(cat "$BAT/capacity" 2>/dev/null)
  if [ -n "$CAP" ] && [ "$CAP" -ge "$CAP_MAX" ]; then
    IDLE_CNT=0
    return 1
  fi
  # ce 已被内核打回 0 —— 有真实电源且未满时需要保活
  CE=$(cat "$BAT/charging_enable" 2>/dev/null)
  if [ "$CE" = "0" ]; then
    IDLE_CNT=0
    return 0
  fi
  # 实际在放电：必须连续 IDLE_NEED 次才认定，避免充电建立期的误判
  IB=$(cat "$BAT/current_now" 2>/dev/null)
  if [ -n "$IB" ] && [ "$IB" -gt 300000 ]; then
    IDLE_CNT=$((IDLE_CNT+1))
    [ "$IDLE_CNT" -ge "$IDLE_NEED" ] && return 1
  else
    IDLE_CNT=0
  fi
  return 0
}

# 停顿期间的低频自查。
# 本机 logcat 输出到管道有块缓冲、-t 0 不支持、inotify 也不产生事件，
# 纯事件驱动做不到，因此用长间隔（默认 5 秒）自查代替。不写日志，开销可忽略。
wait_wake() {
  sleep "$IDLE_POLL"
  return 0
}

readconf() {
  [ -f "$CONF" ] || return 0
  grep -m1 "^$1=" "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/#.*//' | tr -d ' \t\r'
}

loadconf() {
  V=$(readconf ENABLE_CE);       [ -n "$V" ] && ENABLE_CE=$(numonly "$V")
  V=$(readconf ENABLE_THERMAL);  [ -n "$V" ] && ENABLE_THERMAL=$(numonly "$V")
  V=$(readconf CE_TEMP_MAX);     [ -n "$V" ] && CE_TEMP_MAX=$(numonly "$V")
  V=$(readconf CAP_MAX);         [ -n "$V" ] && CAP_MAX=$(numonly "$V")
  V=$(readconf TEMP_6A);         [ -n "$V" ] && TEMP_6A=$(numonly "$V")
  V=$(readconf TEMP_4A);         [ -n "$V" ] && TEMP_4A=$(numonly "$V")
  V=$(readconf TEMP_3A);         [ -n "$V" ] && TEMP_3A=$(numonly "$V")
  V=$(readconf QUIET_6A);        [ -n "$V" ] && QUIET_6A=$(numonly "$V")
  V=$(readconf QUIET_4A);        [ -n "$V" ] && QUIET_4A=$(numonly "$V")
  V=$(readconf QUIET_3A);        [ -n "$V" ] && QUIET_3A=$(numonly "$V")
  V=$(readconf MAX_CURRENT);     [ -n "$V" ] && MAX_CURRENT=$(numonly "$V")
  V=$(readconf IDLE_POLL);       [ -n "$V" ] && IDLE_POLL=$(numonly "$V")
  V=$(readconf IDLE_NEED);       [ -n "$V" ] && IDLE_NEED=$(numonly "$V")
  V=$(readconf ENABLE_CALIBRATE);[ -n "$V" ] && ENABLE_CALIBRATE=$(numonly "$V")
  # 电芯数只认 1 / 2，其余一律按单芯
  V=$(readconf CELLS);           [ -n "$V" ] && CELLS=$(numonly "$V")
  [ "$CELLS" != "2" ] && CELLS=1

  # 充电轮询间隔：支持小数（0.2 / 0.3 / 1），但必须 > 0，否则回退默认
  V=$(readconf CHARGE_POLL)
  if [ -n "$V" ]; then
    V=$(numdec "$V")
    case "$V" in
      ""|*[!0-9.]*) ;;                                   # 含非法字符，忽略
      *) [ -n "$(echo "$V" | tr -d '.0')" ] && CHARGE_POLL="$V" ;;
    esac
  fi
  V=$(readconf ENABLE_SOC_GUARD);[ -n "$V" ] && ENABLE_SOC_GUARD=$(numonly "$V")
  V=$(readconf SOC_80);          [ -n "$V" ] && SOC_80=$(numonly "$V")
  V=$(readconf SOC_90);          [ -n "$V" ] && SOC_90=$(numonly "$V")
  V=$(readconf SOC_95);          [ -n "$V" ] && SOC_95=$(numonly "$V")
  V=$(readconf SOC_A_80);        [ -n "$V" ] && SOC_A_80=$(numonly "$V")
  V=$(readconf SOC_A_90);        [ -n "$V" ] && SOC_A_90=$(numonly "$V")
  V=$(readconf SOC_A_95);        [ -n "$V" ] && SOC_A_95=$(numonly "$V")

  # 按目标电流算出各档 cur_state
  MC=${MAX_CURRENT:-6000000}
  CUR_A=$(find_cur "$MC")
  CUR_B=$(find_cur $(( MC * 2 / 3 )))
  CUR_C=$(find_cur $(( MC / 2 )))
  CUR_D=$(find_cur $(( MC / 3 )))

  CUR_S80=$(find_cur "${SOC_A_80:-5000000}")
  CUR_S90=$(find_cur "${SOC_A_90:-3000000}")
  CUR_S95=$(find_cur "${SOC_A_95:-1500000}")
}

loadconf

stop white_load_charge 2>/dev/null
log "stop white_load_charge -> $(getprop init.svc.white_load_charge)"

CDEV=""
for c in /sys/class/thermal/cooling_device*; do
  [ -f "$c/type" ] || continue
  [ "$(cat "$c/type" 2>/dev/null)" = "battery" ] && { CDEV="$c"; break; }
done

QZ=""
for z in /sys/class/thermal/thermal_zone*; do
  [ -f "$z/type" ] || continue
  [ "$(cat "$z/type" 2>/dev/null)" = "quiet-therm" ] && { QZ="$z/temp"; break; }
done

log "cdev=${CDEV:-未找到} quiet=${QZ:-未找到}"

# 加载上次标定的档位映射（若存在），覆盖默认表后重算各档 cur_state
CAL_LOADED=0
if [ -f "$CAL_FILE" ]; then
  _m=$(cat "$CAL_FILE" 2>/dev/null)
  if [ -n "$_m" ]; then
    CDEV_MAP="$_m"
    CAL_LOADED=1
    loadconf
    log "已加载标定表: $CDEV_MAP"
  fi
fi

log "===== worker 启动 ce=$ENABLE_CE thermal=$ENABLE_THERMAL 目标=${MAX_CURRENT}mA 档位=$CUR_A/$CUR_B/$CUR_C/$CUR_D | 电量保护=$ENABLE_SOC_GUARD 档位=$CUR_S80/$CUR_S90/$CUR_S95 | 充电轮询=${CHARGE_POLL}s 停顿自查=${IDLE_POLL}s 电芯=${CELLS}S | 标定=$([ "$CAL_LOADED" = 1 ] && echo 已加载 || echo 待首次插电) ====="

LAST=""
LASTMODE=""
FIX=0
N=0
IDLE=0
IDLE_CNT=0
CAL_DONE=0
LAST_IDLE_LOG=0
LAST_WAKE_LOG=0

while true; do
  # ---- 不在真正充电：低频自查，不写日志 ----
  if ! need_keepalive; then
    N=$((N+1))
    if [ "$IDLE" != "1" ]; then
      IDLE=1
      sess_end
      NOWS=$(date +%s)
      # 日志节流：同类记录至少间隔 60 秒，避免状态抖动时刷屏
      if [ $((NOWS - LAST_IDLE_LOG)) -ge 60 ]; then
        LAST_IDLE_LOG=$NOWS
        log "进入等待（当前未在充电）type=$(cat "$USB/type" 2>/dev/null) st=$(cat "$BAT/status" 2>/dev/null) cap=$(cat "$BAT/capacity" 2>/dev/null)"
      fi
    fi
    wait_wake
    continue
  fi
  if [ "$IDLE" = "1" ]; then
    IDLE=0
    NOWS=$(date +%s)
    if [ $((NOWS - LAST_WAKE_LOG)) -ge 60 ]; then
      LAST_WAKE_LOG=$NOWS
      log "恢复工作（检测到正在充电）type=$(cat "$USB/type" 2>/dev/null) cap=$(cat "$BAT/capacity" 2>/dev/null)"
    fi
    [ -n "$(pidof WHITE-LOAD-CHARGE)" ] && stop white_load_charge 2>/dev/null
  fi

  N=$((N+1))
  [ $((N % 10)) -eq 0 ] && loadconf

  # 首次进入保活：开始统计会话；若还没标定过映射表，趁现在标一次
  [ "$SESS_ON" = "0" ] && sess_begin
  if [ "$CAL_DONE" = "0" ]; then
    CAL_DONE=1
    if [ "$ENABLE_CALIBRATE" = "1" ] && [ "$CAL_LOADED" = "0" ] && [ -n "$CDEV" ]; then
      calibrate_map && loadconf
    fi
  fi

  TEMP=$(cat "$BAT/temp" 2>/dev/null); TEMP=${TEMP:-0}
  CAP=$(cat "$BAT/capacity" 2>/dev/null); CAP=${CAP:-0}
  HEALTH=$(cat "$BAT/health" 2>/dev/null)
  Q=$(cat "$QZ" 2>/dev/null); Q=${Q:-0}

  # ---- 充电开关保活 ----
  if [ "$ENABLE_CE" = "1" ]; then
    if [ "$(cat "$BAT/charging_enable" 2>/dev/null)" = "0" ]; then
      if [ "$TEMP" -lt "$CE_TEMP_MAX" ] && [ "$CAP" -lt "$CAP_MAX" ] && [ "$HEALTH" = "Good" ]; then
        if echo 1 > "$BAT/charging_enable" 2>/dev/null; then
          FIX=$((FIX+1))
          NOW=$(date '+%H:%M:%S')
          if [ "$NOW" != "$LAST" ]; then
            LAST=$NOW
            log "恢复充电 ce 0->1 temp=$TEMP cap=$CAP 累计=${FIX}次"
          fi
        fi
      fi
    fi
  fi

  # ---- 温控阶梯 + 电量分档（取两者中更保守的档位）----
  if [ -n "$CDEV" ] && { [ "$ENABLE_THERMAL" = "1" ] || [ "$ENABLE_SOC_GUARD" = "1" ]; }; then
    WANT=""
    MODE=""

    if [ "$ENABLE_THERMAL" = "1" ]; then
      if [ "$TEMP" -lt "$TEMP_6A" ] && [ "$Q" -lt "$QUIET_6A" ]; then
        WANT=$CUR_A; MODE="max(${MAX_CURRENT}mA)"
      elif [ "$TEMP" -lt "$TEMP_4A" ] && [ "$Q" -lt "$QUIET_4A" ]; then
        WANT=$CUR_B; MODE="temp2/3"
      elif [ "$TEMP" -lt "$TEMP_3A" ] && [ "$Q" -lt "$QUIET_3A" ]; then
        WANT=$CUR_C; MODE="temp1/2"
      else
        WANT=$CUR_D; MODE="temp1/3"
      fi
    fi

    # 电量越高限流越低。cur_state 越大 = 限流越小，所以取 max 即"更保守"
    if [ "$ENABLE_SOC_GUARD" = "1" ]; then
      SW=""; SM=""
      if   [ "$CAP" -ge "$SOC_95" ]; then SW=$CUR_S95; SM="soc>=${SOC_95}%"
      elif [ "$CAP" -ge "$SOC_90" ]; then SW=$CUR_S90; SM="soc>=${SOC_90}%"
      elif [ "$CAP" -ge "$SOC_80" ]; then SW=$CUR_S80; SM="soc>=${SOC_80}%"
      fi
      if [ -n "$SW" ] && { [ -z "$WANT" ] || [ "$SW" -gt "$WANT" ]; }; then
        WANT=$SW
        MODE="${MODE:+$MODE,}$SM"
      fi
    fi

    if [ -n "$WANT" ]; then
      if [ "$(cat "$CDEV/cur_state" 2>/dev/null)" != "$WANT" ]; then
        echo "$WANT" > "$CDEV/cur_state" 2>/dev/null
      fi
      if [ "$MODE" != "$LASTMODE" ]; then
        LASTMODE="$MODE"
        log "限流档 $MODE (cur=$WANT) temp=$TEMP quiet=$Q cap=$CAP"
      fi
    fi
  fi

  if [ -n "$(pidof WHITE-LOAD-CHARGE)" ]; then
    stop white_load_charge 2>/dev/null
    log "再次 stop white_load_charge"
  fi

  sess_sample
  sleep "$CHARGE_POLL"
done
