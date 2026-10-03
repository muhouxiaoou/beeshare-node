#!/bin/sh
# BeeShare 节点安装脚本（macOS / Linux）。
#   curl -fsSL https://beeshare.cc/install.sh | sh
#   curl -fsSL https://gitee.com/muhouxiaoou/beeshare-node/releases/download/latest/install.sh | sh   （从 Gitee 镜像安装）
#
# 做的事：检测系统和架构 → 下载对应的安装包 → 校验 SHA-256（来自平台的更新清单）→ 试运行确认版本 → 安装。
# 默认装到 ~/.local/bin（root 用户装到 /usr/local/bin），不需要 sudo。
# 可用环境变量：BEESHARE_INSTALL_DIR 指定安装目录；HTTPS_PROXY 让 curl 走代理；NO_COLOR 关闭颜色。
#
# 关于信任：第一次安装信任的是 HTTPS 连接和下载来源（平台或它的 Gitee / GitHub 镜像）；装好之后的每一次更新
# （beeshare-node update）都会用程序里内置的发布公钥验证清单签名，不再依赖网络连接的可信度。
#
# 网络：连平台服务器时常常握手失败（实测十次只成两三次），所以按顺序找来源：Gitee 镜像 → GitHub 镜像 →
# 平台服务器。每个请求都有时限，连不上就换下一个；全都不行时给出走代理的做法。
# 这个文件在 Gitee 上是发行版 latest 的附件（不是仓库文件：仓库里的文本要过内容审核，这个脚本被拦过）。
# 镜像由 beeshare-release mirror 同步，安装包都按清单里的 SHA-256 校验，镜像被篡改也装不上。
set -eu

BASE="${BEESHARE_BASE:-https://beeshare.cc}"
GITEE="${BEESHARE_GITEE:-https://gitee.com/muhouxiaoou/beeshare-node}"
GITHUB="${BEESHARE_GITHUB:-https://github.com/muhouxiaoou/beeshare-node}"
SOURCES="${BEESHARE_SOURCES:-gitee github site}" # 来源顺序；测试里设成 site
TRIES=2                                        # 所有来源都连不上时，整轮再试几次
DL_TRIES=4                                     # 每个来源下载安装包最多试几次（中断后续传）
MAX_TIME="${BEESHARE_MAX_TIME:-20}"            # 取清单的时限（秒）；环境变量只给测试用

# 颜色只在终端里用（curl | sh 时标准输出仍是终端）。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
  C_HONEY="$(printf '\033[1;33m')" C_OK="$(printf '\033[32m')" C_ERR="$(printf '\033[31m')" C_DIM="$(printf '\033[2m')" C_OFF="$(printf '\033[0m')"
else
  C_HONEY="" C_OK="" C_ERR="" C_DIM="" C_OFF=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '%s[%s/4]%s %s\n' "${C_HONEY}" "$1" "${C_OFF}" "$2"; }
note() { printf '      %s%s%s\n' "${C_DIM}" "$*" "${C_OFF}"; }
die() { printf '%s错误: %s%s\n' "${C_ERR}" "$*" "${C_OFF}" >&2; exit 1; }
# 网络失败的提示：多试一次、或者让 curl 走代理。
net_help() {
  {
    say "  · 网络不稳定时，重新运行一次安装命令通常就好了"
    say "  · 本机有代理时，先设置代理再安装，例如："
    say "      export HTTPS_PROXY=http://127.0.0.1:7890"
    say "      curl -fsSL ${GITEE}/releases/download/latest/install.sh | sh"
  } >&2
}

command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装"

say ""
say "  ${C_HONEY}🐝 蜂享 BeeShare${C_OFF} · 节点安装"
say "  ${C_DIM}分享 · 连接 · 共赢 —— 把闲置的 AI 订阅额度共享出去，每一次成功调用都为你带来收益${C_OFF}"
say ""

# ---- 系统和架构 ----
OS="${BEESHARE_OS:-$(uname -s)}"
case "${OS}" in
  Darwin|darwin) OS=darwin OS_NAME=macOS ;;
  Linux|linux) OS=linux OS_NAME=Linux ;;
  *) die "这个脚本只支持 macOS 和 Linux（当前是 ${OS}）。Windows 请从网站的「添加节点」页面下载 .exe" ;;
esac
ARCH="${BEESHARE_ARCH:-$(uname -m)}"
case "${ARCH}" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64) ARCH=amd64 ;;
  *) die "不支持的 CPU 架构 ${ARCH}（支持 arm64 和 amd64）" ;;
esac
PLATFORM="${OS}-${ARCH}"
step 1 "检测系统：${OS_NAME} ${ARCH}（${PLATFORM}）"
PROXY="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}"
[ -z "${PROXY}" ] || note "使用代理 $(printf '%s' "${PROXY}" | sed 's#//[^@/]*@#//***@#')"

# ---- 校验工具 ----
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "需要 sha256sum 或 shasum 来校验下载的文件"
fi

TMP="$(mktemp -d)"
trap 'rc=$?; rm -rf "${TMP}"; exit "${rc}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

src_label() {
  case "$1" in
    gitee) say "Gitee" ;;
    github) say "GitHub" ;;
    site) say "beeshare.cc" ;;
  esac
}
# Gitee 没有"最新发行版"的直链，读固定标签 latest 发行版里的清单（镜像同步时最后更新）；GitHub 用 releases/latest。
manifest_url() {
  case "$1" in
    gitee) say "${GITEE}/releases/download/latest/manifest.json" ;;
    github) say "${GITHUB}/releases/latest/download/manifest.json" ;;
    site) say "${BASE}/node/manifest.json" ;;
  esac
}
asset_url() { # asset_url <来源> <文件名>
  case "$1" in
    gitee) say "${GITEE}/releases/download/v${VERSION}/$2" ;;
    github) say "${GITHUB}/releases/download/v${VERSION}/$2" ;;
    site) say "${BASE}/download/$2" ;;
  esac
}
for s in ${SOURCES}; do
  case "${s}" in gitee|github|site) ;; *) die "BEESHARE_SOURCES 里有不认识的来源 ${s}（可用 gitee、github、site）" ;; esac
done
curl_reason() { sed -n 's/^curl: ([0-9]*) //p' "${TMP}/curl.err" | head -n 1; }

# ---- 读取清单 ----
# 以 curl 的退出码为准：收到响应头之后才超时或断开时状态码已经是 200，但内容不完整，也算失败。
step 2 "获取最新版本信息…"
SRC=""
ALL404=1
round=1
while :; do
  for s in ${SOURCES}; do
    rc=0
    code="$(curl -sSL --connect-timeout 10 --max-time "${MAX_TIME}" -o "${TMP}/manifest.json" -w '%{http_code}' "$(manifest_url "${s}")" 2>"${TMP}/curl.err")" || rc=$?
    if [ "${rc}" -eq 0 ] && [ "${code}" = 200 ]; then
      SRC="${s}"
      break
    fi
    if [ "${rc}" -eq 0 ] && [ "${code}" = 404 ]; then
      why="还没有发布"
    else
      ALL404=0
      why="$(curl_reason)"
      [ -n "${why}" ] || why="http ${code}"
    fi
    note "$(src_label "${s}") 不可用（${why}）"
  done
  [ -z "${SRC}" ] || break
  [ "${round}" -lt "${TRIES}" ] || break
  round=$((round + 1))
  note "所有来源都没连上，2 秒后再试一轮（${round}/${TRIES}）…"
  sleep 2
done
if [ -z "${SRC}" ]; then
  [ "${ALL404}" = 0 ] || die "平台还没有发布节点安装包，请稍后再试或联系管理员"
  printf '%s错误: 连不上任何下载来源（%s）%s\n' "${C_ERR}" "$(for s in ${SOURCES}; do printf '%s ' "$(src_label "${s}")"; done | sed 's/ $//')" "${C_OFF}" >&2
  net_help
  exit 1
fi

VERSION="$(sed -n 's/^  "version": "\([0-9][0-9.]*\)",\{0,1\}$/\1/p' "${TMP}/manifest.json" | head -n 1)"
[ -n "${VERSION}" ] || die "清单里找不到版本号"

# 清单由 beeshare-release 生成，格式固定：每个平台一段 "平台": { "file": ..., "sha256": ..., "size": ... }
FILE="$(awk -v p="\"${PLATFORM}\": {" 'index($0,p){f=1;next} f&&/"file":/{gsub(/.*"file": "|",?$/,"");print;exit}' "${TMP}/manifest.json")"
WANT_SUM="$(awk -v p="\"${PLATFORM}\": {" 'index($0,p){f=1;next} f&&/"sha256":/{gsub(/.*"sha256": "|",?$/,"");print;exit}' "${TMP}/manifest.json")"
SIZE="$(awk -v p="\"${PLATFORM}\": {" 'index($0,p){f=1;next} f&&/"size":/{gsub(/[^0-9]/,"");print;exit}' "${TMP}/manifest.json")"
[ -n "${FILE}" ] && [ -n "${WANT_SUM}" ] || die "最新版本 ${VERSION} 里没有 ${PLATFORM} 的安装包"
case "${FILE}" in
  */*|*..*|"") die "清单里的文件名不合法: ${FILE}" ;;
esac
case "${FILE}" in beeshare-node-*) ;; *) die "清单里的文件名不合法: ${FILE}" ;; esac
case "${WANT_SUM}" in
  *[!0-9a-f]*) die "清单里的校验值不合法" ;;
esac
[ "${#WANT_SUM}" -eq 64 ] || die "清单里的校验值长度不对"
note "最新版本 ${VERSION}（来源：$(src_label "${SRC}")）"

# ---- 下载并校验 ----
SIZE_TEXT=""
[ -z "${SIZE}" ] || SIZE_TEXT="，$(awk -v b="${SIZE}" 'BEGIN{printf "%.1f MB", b/1048576}')"
step 3 "下载安装包（${FILE}${SIZE_TEXT}）…"
# 先从拿到清单的来源下载，失败或校验不通过再换其他来源（内容相同，所以已下载的部分可以接着续传）。
# 速度低于 1 KB/s 持续 30 秒就当作卡住；中断后续传（服务器不支持续传时从头下载）。
# 以 curl 的退出码为准：中途断开时状态码已经是 200，但文件不完整，必须重试，不能拿去校验。
# 终端里显示进度条（curl 把进度写到标准错误，不会混进状态码）。
ORDER="${SRC}"
for s in ${SOURCES}; do [ "${s}" = "${SRC}" ] || ORDER="${ORDER} ${s}"; done
OUT="${TMP}/beeshare-node"
GOT=""
BAD_SUM=0
NET_FAIL=0
HTTP_FAIL=""
for s in ${ORDER}; do
  URL="$(asset_url "${s}" "${FILE}")"
  [ "${s}" = "${SRC}" ] || note "改从 $(src_label "${s}") 下载…"
  n=1
  while :; do
    RESUME=""
    [ ! -s "${OUT}" ] || RESUME="-C -"
    rc=0
    if [ -t 2 ]; then
      DL_CODE="$(curl -L --progress-bar ${RESUME} --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "${OUT}" -w '%{http_code}' "${URL}")" || rc=$?
    else
      DL_CODE="$(curl -sSL ${RESUME} --connect-timeout 10 --speed-limit 1024 --speed-time 30 -o "${OUT}" -w '%{http_code}' "${URL}" 2>"${TMP}/curl.err")" || rc=$?
    fi
    [ "${rc}" -eq 0 ] && break
    [ "${rc}" -ne 33 ] || rm -f "${OUT}" # 33：服务器不支持续传，下次从头下载
    [ "${n}" -lt "${DL_TRIES}" ] || break
    n=$((n + 1))
    [ ! -t 2 ] || printf '\n' >&2 # 进度条那一行没有换行
    if [ -s "${OUT}" ]; then HOW="接着已下载的部分续传"; else HOW="重新下载"; fi
    note "下载中断，正在${HOW}（${n}/${DL_TRIES}）…"
    sleep 2
  done
  if [ "${rc}" -ne 0 ]; then
    [ ! -t 2 ] || printf '\n' >&2
    note "$(src_label "${s}") 下载失败"
    NET_FAIL=1
    continue # 保留已下载的部分，换来源接着续传
  fi
  case "${DL_CODE}" in
    200|206) ;;
    *)
      note "$(src_label "${s}") 返回 http ${DL_CODE}"
      HTTP_FAIL="${HTTP_FAIL}${HTTP_FAIL:+、}$(src_label "${s}") 返回 http ${DL_CODE}"
      rm -f "${OUT}"
      continue
      ;;
  esac
  note "校验 SHA-256…"
  if [ "$(sha256 "${OUT}")" = "${WANT_SUM}" ]; then
    GOT="${s}"
    break
  fi
  note "从 $(src_label "${s}") 下载的文件和清单不一致，已丢弃"
  BAD_SUM=1
  rm -f "${OUT}"
done
if [ -z "${GOT}" ]; then
  [ "${BAD_SUM}" = 0 ] || die "下载文件的 SHA-256 与清单不一致，已放弃安装（可能下载损坏或被篡改）"
  if [ "${NET_FAIL}" = 0 ] && [ -n "${HTTP_FAIL}" ]; then die "下载失败：${HTTP_FAIL}"; fi
  printf '%s错误: 下载失败，连不上下载来源或速度太慢%s\n' "${C_ERR}" "${C_OFF}" >&2
  net_help
  exit 1
fi
chmod 755 "${TMP}/beeshare-node"

# ---- 试运行 ----
GOT_VER="$("${TMP}/beeshare-node" version 2>/dev/null || true)"
[ "${GOT_VER}" = "${VERSION}" ] || die "新程序无法在本机运行或版本不符（得到 '${GOT_VER}'，应为 '${VERSION}'）"
note "校验通过，试运行正常"

# ---- 安装 ----
if [ -n "${BEESHARE_INSTALL_DIR:-}" ]; then
  DIR="${BEESHARE_INSTALL_DIR}"
elif [ "$(id -u)" = "0" ]; then
  DIR=/usr/local/bin
else
  DIR="${HOME}/.local/bin"
fi
step 4 "安装到 ${DIR}…"
mkdir -p "${DIR}" || die "不能创建安装目录 ${DIR}"
# 先复制到目标目录再改名：改名是原子的，不会留下写了一半的程序；已在运行的旧版本不受影响。
cp "${TMP}/beeshare-node" "${DIR}/.beeshare-node.new.$$" || die "不能写入 ${DIR}（可设置 BEESHARE_INSTALL_DIR 换一个目录）"
mv -f "${DIR}/.beeshare-node.new.$$" "${DIR}/beeshare-node" || { rm -f "${DIR}/.beeshare-node.new.$$"; die "安装失败"; }

say ""
say "${C_OK}✓ 已安装 beeshare-node ${VERSION}${C_OFF} → ${DIR}/beeshare-node"
case ":${PATH}:" in
  *":${DIR}:"*) ;;
  *) say "提示：${DIR} 不在你的 PATH 里。可以运行 export PATH=\"${DIR}:\${PATH}\"，或用完整路径 ${DIR}/beeshare-node。" ;;
esac
say ""
say "下一步："
say "  1. 在网站「节点 → 添加节点」里生成绑定码：${BASE}/nodes"
say "  2. beeshare-node bind <绑定码>"
say "  3. beeshare-node install-service       （长期运行：开机自启、崩溃自动恢复、自动更新）"
say "     beeshare-node run                   （前台运行，用来试一试）"
say ""
say "  beeshare-node console                  打开本机的网页控制台（也可以在那里绑定、设置代理）"
say "  beeshare-node doctor                   出问题时先运行它，逐项检查并给出建议"
say "  以后更新：beeshare-node update"
say ""
say "  ${C_HONEY}欢迎加入蜂享。${C_OFF}${C_DIM}使用指南和收益规则见 ${BASE}${C_OFF}"
