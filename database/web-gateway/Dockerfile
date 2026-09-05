FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY gateway.py .

ENV EFELANT_WS_PORT=5433
EXPOSE 5433
CMD ["python", "-u", "gateway.py"]
