# =============================================================================
# Dockerfile — Unified Marketplace Gateway
# Builds a custom Apache APISIX image with custom plugins, adapters, and utils.
# =============================================================================

FROM apache/apisix:3.17.0-debian

LABEL maintainer="Marketplace Gateway Team"
LABEL description="Apache APISIX with Unified Marketplace Gateway custom plugins"

# Install curl for healthcheck and debugging
# Base image runs as non-root, so switch to root for apt install
USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
# Create webhook data directory (writable by apisix user)
RUN mkdir -p /webhook-data && chown apisix:apisix /webhook-data

USER apisix

# Copy custom Lua modules into the custom path
COPY apisix/plugins/       /usr/local/apisix/custom/apisix/plugins/
COPY apisix/adapters/      /usr/local/apisix/custom/adapters/
COPY apisix/utils/         /usr/local/apisix/custom/utils/
COPY apisix/credentials/   /usr/local/apisix/custom/credentials/
COPY apisix/mappings/      /usr/local/apisix/custom/mappings/
COPY apisix/update-config.json /usr/local/apisix/custom/update-config.json
COPY apisix/standardization-config.json /usr/local/apisix/custom/standardization-config.json
COPY apisix/content-mapping.json /usr/local/apisix/custom/content-mapping.json
COPY config-center/ /usr/local/apisix/custom/config-center/

# Set LUA_PATH to include custom modules
ENV LUA_PATH="/usr/local/apisix/custom/?.lua;/usr/local/apisix/?.lua;/usr/local/apisix/apisix/?.lua;;"

# Copy credentials seed file
COPY credentials/credentials.json /credentials/credentials.json

# APISIX 3.17+ includes the embedded dashboard at /usr/local/apisix/ui/
# enable_admin_ui: true in config.yaml activates the /ui/ route

EXPOSE 9080 9180

CMD ["apisix", "start"]
