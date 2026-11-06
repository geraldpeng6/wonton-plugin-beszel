# shellcheck shell=bash
# Beszel：sso=proxy（网关带 X-Wonton-User-Email 代登录）；清单没有 mcp。
# 历史数据算用户数据：data_write 改这台服务器的名字并确认已经有历史记录，data_check 在升级、重装后核对还在。
SYSTEM_ID=wontonlocal0000
export DATA_NA=0

web_assert() { grep -qi '<title>.*beszel' <<<"$(tr -d '\n' | head -c 4000)"; }   # 标准输入：SPA 首页 HTML

identity_check() { # 应用自己的当前用户接口：认出的是主人，而且是管理员
  local out email
  out="$(dweb /api/collections/users/auth-refresh -X POST)" || { echo "auth-refresh 失败：$out"; return 1; }
  grep -q '"role":"admin"' <<<"$out" || { echo "不是管理员：$(head -c 200 <<<"$out")"; return 1; }
  email="${SMOKE_OWNER_EMAIL:-$(sed -n 's/^WONTON_OWNER_EMAIL=//p' "${dir:-.}/.wonton/.env" 2>/dev/null | tail -1)}"
  grep -qF "\"email\":\"$email\"" <<<"$out" || { echo "认出的不是主人（$email）：$(head -c 200 <<<"$out")"; return 1; }
}

data_marker() { printf 'keep-%s' "${E2E_INSTANCE:-${SMOKE_INSTANCE:-dev}}"; }

data_write() { # 改服务器名字，并确认已经攒下历史记录
  local marker rows
  dweb --fresh / -L >/dev/null || { echo "重建会话失败"; return 1; }
  marker="$(data_marker)"
  for _ in $(seq 1 60); do
    rows="$(dweb "/api/collections/system_stats/records?perPage=1&fields=id")" || { echo "查历史失败：$rows"; return 1; }
    grep -q '"totalItems":0' <<<"$rows" || break
    sleep 2
  done
  if grep -q '"totalItems":0' <<<"$rows"; then echo "一直没有历史记录：$rows"; return 1; fi
  dweb "/api/collections/systems/records/$SYSTEM_ID" -X PATCH \
    -H 'Content-Type: application/json' -d "{\"name\":\"$marker\"}" | grep -q "\"name\":\"$marker\"" ||
    { echo "改名没生效"; return 1; }
  return 0
}

data_check() { # 名字和历史都还在。重装、升级会重建核心，会话要重来
  local marker out
  dweb --fresh / -L >/dev/null || { echo "重建会话失败"; return 1; }
  marker="$(data_marker)"
  out="$(dweb "/api/collections/systems/records/$SYSTEM_ID")" || { echo "查服务器失败：$out"; return 1; }
  grep -qF "\"name\":\"$marker\"" <<<"$out" || { echo "改过的名字丢了：$(head -c 200 <<<"$out")"; return 1; }
  out="$(dweb "/api/collections/system_stats/records?perPage=1&fields=id")" || { echo "查历史失败：$out"; return 1; }
  if grep -q '"totalItems":0' <<<"$out"; then echo "历史记录没了"; return 1; fi
  return 0
}
