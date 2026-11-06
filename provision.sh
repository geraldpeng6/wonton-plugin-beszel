#!/bin/sh
# 一次性服务，两个步骤（参数是步骤名）。只在安装、升级、重建和每次启动时跑，必须幂等：
#   keys     把 Hub 当前的公钥交给 Agent，并把主人当前的邮箱同步给管理员和登记用的超级用户。
#            Agent 起来之前跑（它没有公钥不会启动）。
#   register Agent 连上以后，在 Hub 里登记这台服务器；已登记的不动（名字和历史归用户）。
# 上游没有“无界面登记机器”的接口，这里用 PocketBase 的超级用户 API 做。
set -eu

# 只和同一个插件网络里的 hub 说话。宿主上的 Docker 配置会把它自己的代理变量塞进容器，代理多半不解析
# `hub` 这类容器名（实测返回 502 空响应），所以这里一律直连。
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY

mode=${1:?用法：provision.sh keys|register}
base=http://hub:8090
socket=/beszel_socket/beszel.sock
system_id=wontonlocal0000
key_file=/var/lib/beszel-agent/authorized_key
# 超级用户只用来登记，和主人没有关系；首次从主人邮箱改成这个固定地址，主人以后改邮箱也不影响登记。
provisioner_email=beszel-provisioner@wonton.invalid
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

log() { printf '%s\n' "$*" >&2; }

json() { # <字段>：从 $work/body 里取字符串值
  sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$work/body" | tail -1
}

call() { # <方法> <路径> [令牌] [JSON 体]：响应体写进 $work/body，返回 HTTP 状态
  method=$1 path=$2 token=${3-} data=${4-}
  set -- -sS -o "$work/body" -w '%{http_code}' -X "$method"
  [ -n "$token" ] && set -- "$@" -H "Authorization: Bearer $token"
  if [ -n "$data" ]; then
    set -- "$@" -H 'Content-Type: application/json' --data-binary "$data"
  fi
  curl "$@" "$base$path"
}

# 等 Hub 迁移完：健康检查过后数据库才可用，仍然重试到能登录，最多约 60 秒。
token=
attempt=0
while :; do
  attempt=$((attempt + 1))
  status=$(call POST /api/collections/_superusers/auth-with-password '' \
    "{\"identity\":\"$provisioner_email\",\"password\":\"$WONTON_SECRET_OWNER_PASSWORD\"}")
  if [ "$status" != 200 ]; then
    status=$(call POST /api/collections/_superusers/auth-with-password '' \
      "{\"identity\":\"$WONTON_OWNER_EMAIL\",\"password\":\"$WONTON_SECRET_OWNER_PASSWORD\"}")
  fi
  [ "$status" = 200 ] && break
  if [ "$attempt" -ge 30 ]; then
    log "登录 Hub 失败（HTTP $status）：$(cat "$work/body")"
    exit 1
  fi
  sleep 2
done
token=$(json token)
record=$(grep -o '"record":{[^}]*}' "$work/body" | head -1)
super_id=$(printf '%s' "$record" | sed -n 's/.*"id":"\([a-z0-9]*\)".*/\1/p')
super_email=$(printf '%s' "$record" | sed -n 's/.*"email":"\([^"]*\)".*/\1/p')

# 超级用户换成固定邮箱，主人改了邮箱也不会让下一次登录进不来。超级用户身份可以只改邮箱，
# 不动密码（带密码字段会让令牌作废）。
swap_superuser() {
  [ "$super_email" = "$provisioner_email" ] && return 0
  status=$(call PATCH "/api/collections/_superusers/records/$super_id" "$token" "{\"email\":\"$provisioner_email\"}")
  [ "$status" = 200 ] || { log "改超级用户邮箱失败（HTTP $status）：$(cat "$work/body")"; exit 1; }
}

# 管理员记录的邮箱跟着主人当前的值走：网关按邮箱认人，代登录头里的值变了要跟上。
# 容器里的 WONTON_OWNER_EMAIL 是建容器时的快照，所以每次启动都覆盖成当前值。
status=$(call GET '/api/collections/users/records?perPage=1&filter=role%3D%22admin%22' "$token")
[ "$status" = 200 ] || { log "查管理员失败（HTTP $status）：$(cat "$work/body")"; exit 1; }
admin_id=$(grep -o '"id":"[a-z0-9]*"' "$work/body" | tail -1 | sed 's/.*:"//; s/"$//')
[ -n "$admin_id" ] || { log "Hub 里没有管理员（USER_EMAIL 没生效？）"; exit 1; }
# 超级用户身份改别人的邮箱不用旧密码。
status=$(call PATCH "/api/collections/users/records/$admin_id" "$token" \
  "{\"email\":\"$WONTON_OWNER_EMAIL\",\"verified\":true}")
[ "$status" = 200 ] || { log "同步管理员邮箱失败（HTTP $status）：$(cat "$work/body")"; exit 1; }

# Agent 只认 Hub 当前的公钥。密钥存在 hub 的数据目录里，保留数据的重装也还是它。
status=$(call GET /api/beszel/info "$token")
[ "$status" = 200 ] || { log "取 Hub 公钥失败（HTTP $status）：$(cat "$work/body")"; exit 1; }
key=$(json key)
[ -n "$key" ] || { log "Hub 没给公钥：$(cat "$work/body")"; exit 1; }
printf '%s\n' "$key" >"$key_file.tmp"
chmod 644 "$key_file.tmp"
mv "$key_file.tmp" "$key_file"

if [ "$mode" = keys ]; then
  swap_superuser
  log "公钥已写入 $key_file"
  exit 0
fi

# 按套接字登记这台服务器；系统 id 固定，详情页地址因此不变。
status=$(call GET "/api/collections/systems/records/$system_id" "$token")
if [ "$status" != 200 ]; then
  status=$(call POST /api/collections/systems/records "$token" \
    "{\"id\":\"$system_id\",\"name\":\"Server\",\"host\":\"$socket\",\"port\":\"45876\",\"users\":[\"$admin_id\"],\"status\":\"pending\"}")
  if [ "$status" != 200 ]; then
    status=$(call GET "/api/collections/systems/records/$system_id" "$token")
    [ "$status" = 200 ] || { log "登记服务器失败（HTTP $status）：$(cat "$work/body")"; exit 1; }
  fi
fi
swap_superuser
log "已登记 $system_id"
