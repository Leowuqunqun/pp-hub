#!/bin/bash
# pp-hub 冒烟测试 —— 一条命令跑完 M1–M6 的验收项
# 用法：./Tests/smoke.sh          （全部检查，输出 PASS/FAIL）
#       ./Tests/smoke.sh --quiet  （只输出结论行）
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
APP="build/pp-hub.app"
BIN="$APP/Contents/MacOS/pp-hub"
LOG="$HOME/Library/Application Support/pp-hub/log.txt"
QUIET=${1:-}

pass=0; fail=0; manual=0
declare -a FAILED

ok()   { pass=$((pass+1)); [ "$QUIET" = "--quiet" ] || printf "  ✅ %s\n" "$1"; }
bad()  { fail=$((fail+1)); FAILED+=("$1"); printf "  ❌ %s\n" "$1"; }
note() { [ "$QUIET" = "--quiet" ] || printf "  ℹ️  %s\n" "$1"; }
section() { [ "$QUIET" = "--quiet" ] || printf "\n%s\n" "$1"; }

# 最近一次启动之后的日志（避免把历史记录当成当前状态）
since_launch() {
    local marker
    marker=$(grep -n "===== 启动 =====" "$LOG" 2>/dev/null | tail -1 | cut -d: -f1)
    [ -z "$marker" ] && return 1
    tail -n +"$marker" "$LOG"
}

section "M1 · 骨架"

if [ -x "$BIN" ]; then ok "构建产物存在（$APP）"; else bad "构建产物缺失：先跑 ./build.sh"; fi

pid=$(pgrep -f "MacOS/pp-hub" | head -1)
if [ -n "$pid" ]; then ok "进程在跑（pid=$pid）"; else bad "进程未运行"; fi

count=$(pgrep -f "MacOS/pp-hub" 2>/dev/null | wc -l | tr -d ' ')   # macOS 的 pgrep 没有 -c
if [ "${count:-0}" -eq 1 ]; then ok "单实例（没有重复进程）"; else bad "进程数 = ${count}（应为 1）"; fi

if plutil -p "$APP/Contents/Info.plist" 2>/dev/null | grep -qE '"LSUIElement" => (1|true)'; then
    ok "LSUIElement=1（不占 Dock）"
else bad "LSUIElement 未设置"; fi

section "权限与输入"

if since_launch | grep -q "辅助功能权限 = 已授权"; then ok "辅助功能已授权"; else bad "辅助功能未授权（系统设置 → 隐私与安全性 → 辅助功能）"; fi

bindings=$(since_launch | grep -o "已监听 [0-9]* 个组合键" | tail -1 | grep -o "[0-9]*")
if [ "${bindings:-0}" -ge 10 ]; then ok "全局快捷键已注册（${bindings} 个）"; else bad "快捷键注册数 = ${bindings:-0}（应 ≥10）"; fi

section "M2 · 应用索引与文件搜索"

if "$BIN" --selftest apps calc >/dev/null 2>&1; then ok "应用搜索：calc → 命中"; else bad "应用搜索失败"; fi
if "$BIN" --selftest apps 计算器 >/dev/null 2>&1; then ok "应用搜索：中文「计算器」→ 命中"; else bad "中文应用搜索失败"; fi
if timeout 15 "$BIN" --selftest files SESSION >/dev/null 2>&1; then ok "文件搜索：SESSION → 命中"; else bad "文件搜索失败（Spotlight 索引不可用？）"; fi

section "M3 · 窗口吸附"

snap_out=$("$BIN" --selftest snaps 2>&1)
if echo "$snap_out" | grep -q "几何全部通过"; then
    ok "吸附几何：$(echo "$snap_out" | grep -c '^  ') 种布局全部通过"
else
    bad "吸附几何有问题"; echo "$snap_out" | sed 's/^/      /'
fi

section "M4 · 语音听写"

if since_launch | grep -q "预热池就绪"; then ok "识别会话预热完成"; else bad "识别会话未预热（看日志 asr 行）"; fi
if since_launch | grep -q "asr: 会话就绪"; then ok "端侧识别引擎就绪"; else bad "识别引擎未就绪"; fi

offline_out=$("$BIN" --selftest offline 2>&1)
if echo "$offline_out" | grep -q "断网降级正常"; then
    ok "断网降级（润色打不到网时文本照常返回）"
else
    bad "断网降级有问题"; echo "$offline_out" | sed 's/^/      /'
fi

# 中文关键词必须能搜到文件（曾经的 bug：冷启动超时 → 空结果被缓存 → 永久搜不到）
zh_tmp="$HOME/pphub-smoke-中文回归-$$.txt"
echo x > "$zh_tmp"
/usr/bin/mdimport "$zh_tmp" >/dev/null 2>&1
sleep 1
zh_out=$("$BIN" --selftest files "中文回归" 2>&1)
if echo "$zh_out" | grep -q "pphub-smoke-中文回归"; then
    ok "中文关键词搜到文件（空结果不缓存回归检查）"
else
    bad "中文关键词搜不到文件"; echo "$zh_out" | sed 's/^/      /'
fi
rm -f "$zh_tmp"

panel_out=$("$BIN" --selftest panel 2>&1)
if echo "$panel_out" | grep -q "分组与扁平下标一致"; then
    ok "搜索结果分组（应用在前 / 下标不错位）"
else
    bad "搜索分组有问题"; echo "$panel_out" | sed 's/^/      /'
fi

qs_out=$("$BIN" --selftest qspace 2>&1)
if echo "$qs_out" | grep -q "QSpace 顺从唤起到位\|未安装 QSpace"; then
    ok "QSpace 壳化唤起（开到位 + 读回）"
else
    bad "QSpace 唤起/读回有问题"; echo "$qs_out" | sed 's/^/      /'
fi

clip_out=$("$BIN" --selftest clip 2>&1)
if echo "$clip_out" | grep -q "剪贴板历史往返正常"; then
    ok "剪贴板历史（文本/富文本/图片/文件 + 敏感拦截）"
else
    bad "剪贴板历史往返有问题"; echo "$clip_out" | sed 's/^/      /'
fi

meeting_out=$("$BIN" --selftest meeting 3 2>&1)
if echo "$meeting_out" | grep -q "会议记录链路可用"; then
    ok "会议记录（麦克风 → 文件 → 收尾）"
else
    bad "会议记录链路有问题"; echo "$meeting_out" | sed 's/^/      /'
fi

section "M5 · 常驻消耗"

if [ -n "$pid" ]; then
    rss=$(ps -o rss= -p "$pid" | awk '{printf "%d", $1/1024}')
    if [ "$rss" -lt 120 ]; then ok "内存 ${rss}MB < 120MB"; else bad "内存 ${rss}MB ≥ 120MB"; fi

    cpu_max=0
    for _ in 1 2 3; do
        c=$(ps -o %cpu= -p "$pid" | awk '{printf "%d", $1}')
        [ "${c:-0}" -gt "$cpu_max" ] && cpu_max=$c
        sleep 1
    done
    if [ "$cpu_max" -lt 1 ]; then ok "空闲 CPU ${cpu_max}% < 1%"; else bad "空闲 CPU ${cpu_max}% ≥ 1%"; fi
fi

if since_launch | grep -q "登录项 = 已开启"; then ok "开机自启已开启"; else bad "登录项未开启"; fi

# 上次启动后不该再有剪贴板采集（能力已下线）
if since_launch | grep -q "clipboard: 采集已启动"; then bad "剪贴板采集仍在运行（应已下线）"; else ok "剪贴板采集已下线"; fi

section "需要人手做的一项（脚本测不了）"
note "断网 + 说一句话：轻点右 ⌘ 说「测试一下」—— 文字应照常上屏（润色失败只记日志，不挡上屏）"
manual=1

printf "\n===== 结果：%d 通过 / %d 失败 / %d 项需人工 =====\n" "$pass" "$fail" "$manual"
if [ "$fail" -gt 0 ]; then
    printf "失败项：\n"
    for f in "${FAILED[@]}"; do printf "  - %s\n" "$f"; done
    exit 1
fi
printf "全部自动项通过 ✅\n"
exit 0
