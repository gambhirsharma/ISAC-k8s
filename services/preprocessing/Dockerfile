FROM python:3.11-slim
WORKDIR /app
COPY requirements-base.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY proto/isac_pb2.py proto/isac_pb2_grpc.py /app/proto/
COPY preprocessing/preprocessing.py .
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1
EXPOSE 50052
CMD ["python3", "preprocessing.py"]
