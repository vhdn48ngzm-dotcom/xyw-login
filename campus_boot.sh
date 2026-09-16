#!/system/bin/sh
# campus_boot.sh —— 开机自动登录"广东校园"(电信校园宽带)+ 全天掉线看门狗
#
# 原理:该校园网用电信 CCTP 加密协议,无法用 curl 直接重放,所以脚本在
#       "离线"时拉起官方 App 借它自动登录,登录成功后立即强杀 App 并清理
#       最近任务卡片,不留任何 App 后台。
#
# WiFi 开关兜底:开机时 WiFi 没开 / 半路关了再开,脚本都不会退出,
#       看门狗一旦发现校园网连上(wlan0 拿到 172.25.x 地址)且未认证,就自动登录。
#
# 部署:本文件放到手机的 /data/adb/service.d/ 下(Magisk/KernelSU/APatch 通用)
#       并 chmod 700。每次开机由 root 自动执行。
# 前提:App 里已保存账号密码且勾选"自动登录"(你的手机已是此状态)

PKG="com.cndatacom.campus.cdccportalgd"
ACT="com.cndatacom.campus.MainActivity"
MODDIR=${0%/*}
LOG="$MODDIR/campus_boot.log"
PIDF="$MODDIR/campus_watchdog.pid"

WATCHDOG=1            # 1=常驻看门狗,全天掉线自动重登;0=仅开机登录一次
CHECK_INTERVAL=120    # 看门狗巡检间隔(秒);想更快恢复可改成 60
CAMPUS_PREFIX='172.25.'   # 校园网网段前缀,不在此网段(家用WiFi/流量)时不动作

MAX_WIFI_WAIT=90      # 开机阶段等 WiFi 就绪的秒数,超过就交给看门狗
MAX_LAUNCH_WAIT=45    # 拉起 App 后最多等它自动登录(秒)
MAX_RETRY=3           # 一轮内失败重试次数

# 主页圆心按钮"点我登录/断开网络"(本机竖屏 1800x2880 实测坐标)
TAP_MAIN_X=893;  TAP_MAIN_Y=1009
# 账号表单页"登录上网"按钮(自动登录失效、停在表单页时才会用到)
TAP_LOGIN_X=900; TAP_LOGIN_Y=2148

log(){ echo "[$(date '+%F %T')] $*" >> "$LOG"; }
# 只探测 WiFi 通路(绑定 wlan0):开着流量/代理上网时不算"在线",避免漏掉校园网认证
online(){ ping -c 1 -W 2 -I wlan0 223.5.5.5 >/dev/null 2>&1; }
wifi_ip(){ ip -4 addr show wlan0 2>/dev/null | grep -q ' inet '; }
campus_ip(){ ip -4 addr show wlan0 2>/dev/null | grep -q "inet $CAMPUS_PREFIX"; }
device_locked(){ # 锁屏/息屏判定
    dumpsys trust 2>/dev/null | grep -q 'deviceLocked=1' && return 0
    dumpsys window policy 2>/dev/null | grep -qE 'showing=true| mIsShowing=true' && return 0
    return 1
}
wait_online(){   # 等待上线,参数=最多秒数
    i=0
    while [ "$i" -lt "$1" ]; do
        online && return 0
        sleep 5; i=$((i+5))
    done
    return 1
}
clear_card(){    # 清掉最近任务里可能残留的卡片
    tid=$(am stack list 2>/dev/null | grep "cdccportalgd" | grep -o "taskId=[0-9]*" | head -1 | cut -d= -f2)
    [ -n "$tid" ] && am stack remove "$tid" >/dev/null 2>&1
}
do_login(){      # 完整登录动作:拉App自动登录→失败补模拟点击→收尾强杀
    try=0
    while [ "$try" -lt "$MAX_RETRY" ]; do
        try=$((try+1))
        # -f 0x00800000 = FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS,启动不留最近任务卡片
        am start -f 0x00800000 -n "$PKG/$ACT" >/dev/null 2>&1
        sleep 3
        wait_online "$MAX_LAUNCH_WAIT" && break
        log "attempt#$try launch-failed, fallback taps"
        input tap "$TAP_MAIN_X" "$TAP_MAIN_Y"          # 主页"点我登录"
        wait_online 15 && break
        input keyevent 4                               # 关键盘/返回
        input tap "$TAP_LOGIN_X" "$TAP_LOGIN_Y"        # 表单页"登录上网"
        wait_online 15 && break
        am force-stop "$PKG"                           # 复位后进入下一轮
        sleep 3
    done
    am force-stop "$PKG"
    clear_card
    online
}

# 单实例锁:看门狗已在跑时,再次手动运行直接退出
oldpid=$(cat "$PIDF" 2>/dev/null)
if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ] && grep -q campus_boot "/proc/$oldpid/cmdline" 2>/dev/null; then
    exit 0
fi
echo $$ > "$PIDF"

: > "$LOG"
log "watchdog-start pid=$$ interval=${CHECK_INTERVAL}s watchdog=$WATCHDOG"

# 1) 开机阶段:离线才需要登录;WiFi 没就绪就短等一会儿,等不到交给看门狗
if ! online; then
    log "offline at boot"
    i=0
    while ! wifi_ip; do
        [ "$i" -ge "$MAX_WIFI_WAIT" ] && break
        sleep 5; i=$((i+5))
    done
    if wifi_ip; then
        # 等解锁(最多10分钟):锁屏时不动作,解锁后立即登录
        i=0
        while device_locked && [ "$i" -lt 600 ]; do
            sleep 10; i=$((i+10))
        done
        if device_locked; then
            log "boot: still locked 10min; leave it to watchdog"
        elif do_login; then
            log "ok: login-success"
        else
            log "fail: login-failed at boot"
        fi
    else
        log "wifi-not-ready; watchdog takes over"
    fi
fi

# 2) 常驻看门狗:锁屏时不检测,解锁后立即巡检,然后每 CHECK_INTERVAL 秒一次
#    - 锁屏/息屏:不做任何网络检测,每10秒只看一眼锁屏状态(开销约20毫秒)
#    - 解锁:立即检测,掉线且在校园网段(含流量/代理在跑的情况)则自动重登
#    (常驻的只是一个 sleep 壳进程,约1~2MB内存;不想要就改成 WATCHDOG=0)
[ "$WATCHDOG" = "1" ] || { log "exit: watchdog-disabled"; exit 0; }
locked_mode=0
idle=0
while true; do
    if device_locked; then
        # 锁屏:不做任何网络检测,每10秒看一眼锁屏状态
        # (屏幕熄灭后系统休眠会把本进程冻结,实际零唤醒、零耗电)
        [ "$locked_mode" = "0" ] && { log "locked: pause checks"; locked_mode=1; }
        idle=0
        sleep 10
        continue
    fi
    if [ "$locked_mode" = "1" ]; then
        log "unlocked: immediate check"
        locked_mode=0
        idle=0
    fi
    if ! online && campus_ip; then
        log "watchdog: offline, re-login"
        if do_login; then log "watchdog: login-success"
        else log "watchdog: login-failed"; fi
        idle=0
    fi
    # 用10秒小步凑满巡检间隔:锁屏能被立刻感知,不会睡过头
    idle=$((idle + 10))
    [ "$idle" -ge "$CHECK_INTERVAL" ] && idle=0
    sleep 10
done
