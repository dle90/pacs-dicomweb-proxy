FROM nginx:1.27-alpine

# envsubst (gettext) for templating ORTHANC_BACKEND_URL into the nginx config
RUN apk add --no-cache gettext

# nginx config TEMPLATE — ${ORTHANC_BACKEND_URL} substituted at startup
COPY nginx.conf /etc/nginx/conf.d/default.conf.template

COPY docker-entrypoint.sh /usr/src/entrypoint.sh
RUN chmod +x /usr/src/entrypoint.sh

EXPOSE 80
CMD ["/usr/src/entrypoint.sh"]
