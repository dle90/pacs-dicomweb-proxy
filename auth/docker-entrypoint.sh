#!/bin/sh
set -e

# ── Orthanc backend ──────────────────────────────────────────────────────────
: "${ORTHANC_BACKEND_URL:=http://orthanc:8042}"

# ── DNS resolver ──────────────────────────────────────────────────────────────
# Used by proxy_pass ($orthanc, re-resolved per request) AND the Lua cosockets
# (resty.http). On Railway the backend (pacs.railway.internal) is IPv6 private DNS
# with a new IP per redeploy; startup-time resolution would crash/go stale. Feed
# nginx the container's own resolver. (Local docker-compose falls back to Docker DNS.)
RESOLVER="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"
: "${RESOLVER:=127.0.0.11}"
case "$RESOLVER" in *:*) RESOLVER="[$RESOLVER]" ;; esac   # nginx wants IPv6 in [brackets]
export RESOLVER

# ── Auth: TWO token sources (HIS + Telerad), each its own key/issuer/audience ──
: "${AUTH_ENABLED:=false}"
: "${HIS_JWT_PUBLIC_KEY:=}";      : "${HIS_JWT_PUBLIC_KEY_BASE64:=}"
: "${HIS_JWT_ISSUER:=}";          : "${HIS_JWT_AUDIENCE:=}"
: "${TELERAD_JWT_PUBLIC_KEY:=}";  : "${TELERAD_JWT_PUBLIC_KEY_BASE64:=}"
: "${TELERAD_JWT_ISSUER:=}";      : "${TELERAD_JWT_AUDIENCE:=}"

case "$AUTH_ENABLED" in
  true|TRUE|True|1|yes|on) AUTH_ENABLED=true ;;
  *)                       AUTH_ENABLED=false ;;
esac

# ── ĐỌC CA (read) security ────────────────────────────────────────────────────
# READ_AUTH_ENABLED=true  -> WADO/QIDO yêu cầu VIEW token bind đúng studyUid.
# READ_JWT_AUDIENCE       -> aud mong đợi của view token (để trống = không kiểm aud,
#                            vẫn kiểm sig/exp/iss + study-binding).
: "${READ_AUTH_ENABLED:=false}"
: "${READ_JWT_AUDIENCE:=}"
case "$READ_AUTH_ENABLED" in
  true|TRUE|True|1|yes|on) READ_AUTH_ENABLED=true ;;
  *)                       READ_AUTH_ENABLED=false ;;
esac

KEY_DIR=/etc/nginx/keys
mkdir -p "$KEY_DIR"

# write_key <dest> <raw_pem> <base64> -> 0 if a key was written, 1 otherwise.
# chmod 644: these are PUBLIC keys (non-secret) and the nginx WORKER runs as an
# unprivileged user (nobody) — 600/root would make io.open fail in access_by_lua.
write_key() {
  if [ -n "$3" ]; then echo "$3" | base64 -d > "$1"; chmod 644 "$1"; return 0; fi
  if [ -n "$2" ]; then printf '%s\n' "$2" > "$1"; chmod 644 "$1"; return 0; fi
  return 1
}

HIS_KEY="$KEY_DIR/his-jwt-public.pem"
TELERAD_KEY="$KEY_DIR/telerad-jwt-public.pem"
HIS_OK=false
TELERAD_OK=false
if write_key "$HIS_KEY"     "$HIS_JWT_PUBLIC_KEY"     "$HIS_JWT_PUBLIC_KEY_BASE64";     then HIS_OK=true;     echo "[entrypoint] HIS key written"; fi
if write_key "$TELERAD_KEY" "$TELERAD_JWT_PUBLIC_KEY" "$TELERAD_JWT_PUBLIC_KEY_BASE64"; then TELERAD_OK=true; echo "[entrypoint] TELERAD key written"; fi

# Build the lua `sources` list — only include a source whose key was provided.
SOURCES=""
if [ "$HIS_OK" = "true" ]; then
  SOURCES="$SOURCES    { name = \"his\", public_key_path = \"$HIS_KEY\", issuer = \"$HIS_JWT_ISSUER\", audience = \"$HIS_JWT_AUDIENCE\" },
"
fi
if [ "$TELERAD_OK" = "true" ]; then
  SOURCES="$SOURCES    { name = \"telerad\", public_key_path = \"$TELERAD_KEY\", issuer = \"$TELERAD_JWT_ISSUER\", audience = \"$TELERAD_JWT_AUDIENCE\" },
"
fi

if [ "$AUTH_ENABLED" = "true" ] && [ "$HIS_OK" != "true" ] && [ "$TELERAD_OK" != "true" ]; then
  echo "[entrypoint] FATAL: AUTH_ENABLED=true but no token-source key provided (HIS_/TELERAD_JWT_PUBLIC_KEY*)." >&2
  exit 1
fi

LUA_DIR=/etc/nginx/lua
mkdir -p "$LUA_DIR"
cat > "$LUA_DIR/jwt_config.lua" <<EOF
return {
  enabled = ${AUTH_ENABLED},
  read_enabled = ${READ_AUTH_ENABLED},
  read_audience = "${READ_JWT_AUDIENCE}",
  sources = {
${SOURCES}  },
}
EOF
echo "[entrypoint] auth enabled=$AUTH_ENABLED his=$HIS_OK (iss='${HIS_JWT_ISSUER}') telerad=$TELERAD_OK (iss='${TELERAD_JWT_ISSUER}')"
echo "[entrypoint] read-auth enabled=$READ_AUTH_ENABLED (read_audience='${READ_JWT_AUDIENCE}')"

# Runtime config for medisync_label: the Orthanc backend used for the async
# post-STOW label calls (/tools/lookup + PUT /studies/{id}/labels/...).
cat > "$LUA_DIR/medisync_runtime.lua" <<EOF
return { orthanc_backend = "${ORTHANC_BACKEND_URL}" }
EOF

# ── Render nginx config ──────────────────────────────────────────────────────
envsubst '${ORTHANC_BACKEND_URL} ${RESOLVER}' \
  < /etc/nginx/nginx.conf.template \
  > /usr/local/openresty/nginx/conf/nginx.conf

exec openresty -g 'daemon off;'
