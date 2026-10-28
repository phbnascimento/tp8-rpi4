# Tag fixa (guia Aula 10): o mesmo Dockerfile gera sempre o mesmo ambiente.
FROM python:3.12.15-slim-bookworm

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 5000
CMD ["python", "app.py"]
