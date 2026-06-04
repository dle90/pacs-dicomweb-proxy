#!/bin/sh
set -e

# The Orthanc the proxy forwards to. Default = docker-compose service name.
: "${ORTHANC_BACKEND_URL:=http://orthanc:8042}"

# Substitute ONLY our own variable into the template — the explicit allow-list
# prevents envsubst from mangling nginx's own $variables ($remote_addr, $uri, ...).
envsubst '${ORTHANC_BACKEND_URL}' \
  < /etc/nginx/conf.d/default.conf.template \
  > /etc/nginx/conf.d/default.conf

exec nginx -g 'daemon off;'
