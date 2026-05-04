# Market Stress Copilot V3 — Shiny + Plumber image
# Single image runs either the Shiny app or the Plumber webhook depending
# on CMD (driven by docker-compose.yml).

FROM rocker/tidyverse:4.4.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Keep aligned with app.R + plumber/webhook.R library() lists
RUN install2.r --error --skipinstalled --ncpus -1 \
    shiny \
    bslib \
    DT \
    dplyr \
    glue \
    jsonlite \
    scales \
    htmltools \
    quantmod \
    httr2 \
    plotly \
    zoo \
    RSQLite \
    DBI \
    tibble \
    dotenv \
    digest \
    plumber \
    later

WORKDIR /app

# Only copy runtime files (docs/Dockerfile/etc. are excluded by .dockerignore)
COPY app.R ./
COPY run_plumber.R ./
COPY R ./R/
COPY plumber ./plumber/
COPY www ./www/
COPY data ./data/

RUN mkdir -p /app/data && chmod -R a+rX /app/www /app/data

EXPOSE 3838 8000

ENV PORT=3838 \
    APPV2_DB_PATH=/app/data/alerts.sqlite

# Default = Shiny. The webhook service overrides CMD in docker-compose.
CMD ["R", "-e", "shiny::runApp('/app', host='0.0.0.0', port=as.integer(Sys.getenv('PORT','3838')), launch.browser=FALSE)"]

# --- Common commands ---
# Build:  docker build -t 5381-app .
# Run:    docker run --rm -p 3838:3838 -e OPENAI_API_KEY="<your-openai-api-key>" 5381-app
# Or:     docker compose up --build
# Cloud:  docker build --platform linux/amd64 -t 5381-app .
