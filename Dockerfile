# 5381 Shiny 应用 — 构建与运行说明见文件末尾注释
# R Shiny — Market Stress Copilot (synced with current app.R dependencies)

FROM rocker/tidyverse:4.4.3

RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# 与 app.R 中 library() 列表一致（quantmod 会拉取 xts / TTR 等）
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
    dotenv

WORKDIR /app

# 仅复制运行所需文件（文档、Plumber 等不打进镜像，减小体积）
COPY app.R ./
COPY R ./R/
COPY www ./www/
COPY data ./data/

RUN mkdir -p /app/data && chmod -R a+rX /app/www /app/data

EXPOSE 3838

ENV PORT=3838

# 监听 0.0.0.0 供容器外访问；PORT 可被云平台覆盖
CMD ["R", "-e", "shiny::runApp('/app', host='0.0.0.0', port=as.integer(Sys.getenv('PORT','3838')), launch.browser=FALSE)"]

# --- 常用命令 ---
# 构建：  docker build -t 5381-app .
# 运行：  docker run --rm -p 3838:3838 -e OPENAI_API_KEY="sk-..." 5381-app
# 或：    docker compose up --build
# 密钥：  勿把 .env 提交到 Git；可用 --env-file .env 或 compose 注入
# 云部署：部分平台需 amd64： docker build --platform linux/amd64 -t 5381-app .
