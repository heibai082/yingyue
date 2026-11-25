FROM python:3.12-slim

WORKDIR /app
COPY server.py source_engine.py ./
COPY static ./static

ENV DATA_DIR=/data \
    PORT=8090 \
    BACKUP_KEEP=14 \
    PYTHONUNBUFFERED=1

VOLUME ["/data"]
EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8090/api/health',timeout=3)" || exit 1

CMD ["python", "server.py"]
