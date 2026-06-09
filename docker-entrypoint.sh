#!/bin/sh
set -e

# The Orthanc the proxy forwards to. Default = docker-compose service name.
: "${ORTHANC_BACKEND_URL:=http://orthanc:8042}"

# nginx resolves proxy_pass hostnames at startup UNLESS the upstream is given as a
# variable AND a `resolver` is configured — then it re-resolves per request. On
# Railway the private DNS (*.railway.internal) hands out a new IP every time the
# upstream redeploys, and startup-time resolution would either crash ("host not
# found in upstream" when pacs is down at boot) or cache a stale IP. So feed nginx
# the container's own resolver and let proxy_pass ($orthanc) re-resolve each request.
RESOLVER="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"
: "${RESOLVER:=127.0.0.11}"
# nginx wants IPv6 resolver addresses wrapped in [brackets].
case "$RESOLVER" in *:*) RESOLVER="[$RESOLVER]" ;; esac
export ORTHANC_BACKEND_URL RESOLVER

# Substitute ONLY our own variables — the explicit allow-list prevents envsubst
# from mangling nginx's own $variables ($orthanc, $request_uri, $remote_addr, ...).
envsubst '${ORTHANC_BACKEND_URL} ${RESOLVER}' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
