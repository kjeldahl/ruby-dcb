FROM mcr.microsoft.com/devcontainers/ruby:3.3

RUN apt-get update && apt-get install -y \
    postgresql \
    postgresql-client \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/home/vscode/.bundle
ENV BUNDLE_FORCE_RUBY_PLATFORM=1
