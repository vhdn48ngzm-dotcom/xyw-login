#!/system/bin/sh
(
  export PATH="/data/adb/magisk:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin:/system/xbin:$PATH"
  export BOXCTL_STDOUT_LOG_LINE=1
  run_dir='/data/user/0/com.boxproxy.box/files/box/run'
  log_file='/data/user/0/com.boxproxy.box/files/box/run/boot.log'
  boxctl='/data/user/0/com.boxproxy.box/files/box/bin/boxctl'
  db='/data/user/0/com.boxproxy.box/files/box/box.db'

  timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date 2>/dev/null || echo "-"
  }

  boot_log() {
    line="$(timestamp) [Info] $*"
    echo "$line" >> "$log_file" 2>/dev/null || true
  }

  log -t BoxProxyBoot '开机自启：准备启动服务' 2>/dev/null || true
  log -t BoxProxyBoot 'waiting for boot animation to stop' 2>/dev/null || true

  while [ "$(getprop init.svc.bootanim 2>/dev/null)" != "stopped" ]; do
    sleep 10
  done

  log -t BoxProxyBoot 'waiting for runtime files' 2>/dev/null || true
  while [ ! -x "$boxctl" ] || [ ! -f "$db" ]; do
    sleep 2
  done
  mkdir -p "$run_dir" 2>/dev/null || exit 1
  : > "$log_file" 2>/dev/null || exit 1
  boot_log '开机自启：准备启动服务'
  log -t BoxProxyBoot 'runtime files are ready' 2>/dev/null || true

  "$boxctl" --db "$db" boot >> "$log_file" 2>&1
  start_code=$?
  if [ "$start_code" -eq 0 ]; then
    boot_log '开机自启：服务启动命令已完成'
  else
    boot_log "$(printf '%s' '启动失败: exit code __CODE__' | sed "s/__CODE__/$start_code/g")"
  fi
) >/dev/null 2>&1 &
exit 0