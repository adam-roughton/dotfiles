FROM python:3.13-alpine
WORKDIR /app
COPY server.py .
HEALTHCHECK --interval=1s --timeout=3s --retries=30 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080')"
CMD ["python", "server.py"]
