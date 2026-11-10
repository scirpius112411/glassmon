FROM python:3.12-alpine
WORKDIR /app
COPY glassmon_server.py install.sh ./
COPY web ./web
COPY agent ./agent
RUN adduser -D -H app
USER app
ENV PORT=8080 PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:${PORT}/healthz || exit 1
CMD ["python", "glassmon_server.py", "serve"]
