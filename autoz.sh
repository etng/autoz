#!/bin/bash
# autoz.sh —— AutoZ 的命令行入口（对 App 内二进制的精简封装，不重复实现逻辑）
#
# 之所以是封装而不是另写一套 curl 脚本：解析时区、提权、校验、发通知这些动作
# 已经在 App 里用系统原生 API 实现好了（URLSession / Security.framework /
# UserNotifications），再写一份 shell 版只会产生两个会各自漂移的实现。
#
# 用法:
#   ./autoz.sh check        仅查询出口 IP 与对应时区，不改系统
#   ./autoz.sh apply        查询并设置系统时区（装了免授权助手则零弹窗）
#   ./autoz.sh set <zone>   直接设为指定 IANA 时区，如 Asia/Tokyo
#   ./autoz.sh restore <zone>  同上（语义化别名）
#   ./autoz.sh system       打印系统时区 / 自动时区开关
#   ./autoz.sh format       打印继承到的时间格式与东八区渲染结果
#   ./autoz.sh menu         打印菜单结构（数据驱动模型，供审查）
#   ./autoz.sh plan [zone]  打印三条通道将执行的命令（不执行）
#   ./autoz.sh backend [helper|native|appleScript]  查看或切换改时区通道
#   ./autoz.sh notify       测试系统通知通道
#   ./autoz.sh install      构建并安装到 /Applications（需要时请求密码）
#
# 免授权模式（装一次，以后改时区零弹窗）:
#   ./autoz.sh helper-status     查看助手状态与 ping 结果
#   ./autoz.sh helper-plan       打印安装/卸载将执行的特权命令（不执行）
#   ./autoz.sh helper-install    安装（会弹一次管理员授权）
#   ./autoz.sh helper-uninstall  卸载（会弹一次管理员授权）
#   ./autoz.sh helper-selftest   助手自测（11 项协议与安全用例，dry-run，无需 root）
#
# 开机自启（用户级 LaunchAgent，写 ~/Library/LaunchAgents/cn.y10n.autoz.plist）:
#   ./autoz.sh login-status      查看开机自启状态
#   ./autoz.sh login-enable      开启开机自启（App 需在 /Applications）
#   ./autoz.sh login-disable     关闭开机自启
set -uo pipefail

cd "$(dirname "$0")"
APP="$PWD/dist/AutoZ.app"
BIN="$APP/Contents/MacOS/AutoZ"

if [[ ! -x "$BIN" ]]; then
  echo "未找到构建产物，先执行 build.sh …"
  ./build.sh >/dev/null || { echo "构建失败"; exit 1; }
fi

cmd="${1:-help}"
shift || true

case "$cmd" in
  check|query)   exec "$BIN" --check ;;
  apply|sync)    exec "$BIN" --apply ;;
  set|restore)   [[ $# -ge 1 ]] || { echo "用法: ./autoz.sh set <IANA 时区>"; exit 1; }
                 exec "$BIN" --set "$1" ;;
  system|status) exec "$BIN" --system ;;
  format|fmt)    exec "$BIN" --format ;;
  menu)          exec "$BIN" --menu ;;
  plan)          exec "$BIN" --plan "$@" ;;
  backend)       exec "$BIN" --backend "$@" ;;
  notify|notify-test) exec "$BIN" --notify-test ;;
  notify-status) exec "$BIN" --notify-status ;;
  helper|helper-status) exec "$BIN" --helper-status ;;
  helper-plan)   exec "$BIN" --helper-plan ;;
  helper-install) exec "$BIN" --helper-install ;;
  helper-uninstall) exec "$BIN" --helper-uninstall ;;
  helper-selftest)
    [[ -x ./build/autoz-helper ]] || { echo "未找到 build/autoz-helper，先跑 ./build.sh"; exit 1; }
    exec ./build/autoz-helper --selftest ;;
  install)       exec ./build.sh --install ;;
  login-status|login)  exec "$BIN" --login-status ;;
  login-enable)  exec "$BIN" --login-enable ;;
  login-disable) exec "$BIN" --login-disable ;;
  run|start)     exec /usr/bin/open "$APP" ;;
  help|-h|--help)
    # 只打印文件开头的注释块（遇到第一行非注释即停）
    /usr/bin/awk '/^#!/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0" ;;
  *) echo "未知命令: ${cmd}（./autoz.sh help 查看用法）"; exit 1 ;;
esac
