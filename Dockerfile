# Avertis — one Cloud Run service serving both the API and the command centre.
#
# Built from the repository root, not from backend/, because the image needs
# command-center/ too. Deploying with only the backend in context produces an
# API with no dashboard and nothing to tell you so.
#
#   gcloud run deploy avertis --source . --region asia-south1
FROM python:3.12-slim

WORKDIR /app

COPY backend/requirements.txt .
# The Google libraries are installed here rather than left optional: on Cloud
# Run the credentials usually exist, and an image that cannot use them is a
# wasted deployment.
RUN pip install --no-cache-dir -r requirements.txt \
    google-genai google-cloud-firestore google-cloud-storage

COPY backend/avertis_backend/ ./avertis_backend/
COPY command-center/ ./command-center/

ENV COMMAND_CENTRE_DIR=/app/command-center

# Cloud Run supplies PORT.
ENV PORT=8080
CMD exec uvicorn avertis_backend.main:app --host 0.0.0.0 --port ${PORT}
