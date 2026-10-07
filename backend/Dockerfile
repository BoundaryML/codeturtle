FROM node:22.20.0-bookworm-slim AS frontend
WORKDIR /ui
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --ignore-scripts
COPY frontend/ ./
RUN npm run build

FROM python:3.12.12-slim-bookworm
ARG BAML_RUNTIME_URL
ARG BAML_RUNTIME_SHA256
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY cli/scripts/install_runtime.py /tmp/install_runtime.py
RUN python /tmp/install_runtime.py --url "$BAML_RUNTIME_URL" --sha256 "$BAML_RUNTIME_SHA256" --destination /usr/local/bin/baml \
    && baml --version | grep -F '0.20.2-nightly.20261004.a' \
    && rm /tmp/install_runtime.py
COPY backend/requirements.txt /app/backend/requirements.txt
RUN mkdir -p /app/backend/.baml && chown -R 10001:10001 /app/backend
RUN pip install --no-cache-dir -r /app/backend/requirements.txt && useradd --uid 10001 --create-home turtle
COPY backend/baml.toml backend/crypto.py /app/backend/
COPY backend/baml_src/ /app/backend/baml_src/
COPY cli/baml_src/models.baml /app/contracts/models.baml
COPY --from=frontend /ui/dist /app/frontend
ENV CODETURTLE_CRYPTO_PATH=/app/backend/crypto.py CODETURTLE_MODELS_PATH=/app/contracts/models.baml CODETURTLE_FRONTEND_DIR=/app/frontend
USER 10001
WORKDIR /app/backend
EXPOSE 8080
CMD ["baml", "--agent-skill-check", "off", "run", "main", "--", "--addr", "0.0.0.0:8080"]
