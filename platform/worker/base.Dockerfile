# Base image for role containers. Build context: platform/
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

COPY worker/requirements.txt /opt/worker/requirements.txt
RUN pip install --no-cache-dir -r /opt/worker/requirements.txt

COPY protocol /opt/worker/protocol
COPY worker /opt/worker
RUN chmod +x /opt/worker/entrypoint.sh /opt/worker/engines/*/run

# uid 1000 matches the host user so files in data/ keep the right owner
RUN useradd --create-home --uid 1000 agent \
    && mkdir -p /workspaces /memory /logs \
    && chown agent:agent /workspaces /memory /logs
USER agent
WORKDIR /workspaces

ENV PYTHONUNBUFFERED=1 PYTHONPATH=/opt/worker
EXPOSE 9000
ENTRYPOINT ["/opt/worker/entrypoint.sh"]
