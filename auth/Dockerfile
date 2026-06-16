# alpine-fat ships luarocks + build deps needed to install lua-resty-jwt.
FROM openresty/openresty:alpine-fat

# envsubst (gettext) + JWT lib. Use the maintained cdbattags fork via luarocks:
# the old SkyLothar/opm build bundles a resty.evp that calls EVP_MD_CTX_create,
# a symbol removed in OpenSSL 1.1+ (this image's OpenSSL) -> "Symbol not found".
# cdbattags' fork uses EVP_MD_CTX_new and works with modern OpenSSL.
RUN apk add --no-cache gettext \
 && luarocks install lua-resty-jwt \
 && luarocks install lua-resty-http

# Lua modules + nginx config TEMPLATE (${ORTHANC_BACKEND_URL} substituted at start)
# Paths are relative to the REPO ROOT build context (Railway builds with the repo
# root as context + dockerfilePath=auth/Dockerfile; docker-compose uses
# context: . + dockerfile: auth/Dockerfile to match).
COPY auth/lua/medisync_auth.lua  /etc/nginx/lua/medisync_auth.lua
COPY auth/lua/medisync_label.lua /etc/nginx/lua/medisync_label.lua
COPY auth/nginx.conf           /etc/nginx/nginx.conf.template

COPY auth/docker-entrypoint.sh /usr/src/entrypoint.sh
RUN chmod +x /usr/src/entrypoint.sh

EXPOSE 80
CMD ["/usr/src/entrypoint.sh"]
