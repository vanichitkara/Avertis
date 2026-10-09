# Cloud Run deployment (plan §38).
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
# Install the Google libraries here: on Cloud Run the credentials usually
# exist, and an image that cannot use them is a wasted deployment.
RUN pip install --no-cache-dir -r requirements.txt \
    google-genai google-cloud-firestore google-cloud-storage

COPY avertis_backend/ ./avertis_backend/

# Cloud Run supplies PORT.
ENV PORT=8080
CMD exec uvicorn avertis_backend.main:app --host 0.0.0.0 --port ${PORT}
