FROM mcr.microsoft.com/devcontainers/ruby:3.3

ENV BUNDLE_PATH=/home/vscode/.bundle
ENV BUNDLE_FORCE_RUBY_PLATFORM=1

RUN apt-get update && apt-get install -y \
    postgresql \
    postgresql-client \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# gh (GitHub CLI)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# claude (Claude Code CLI) — requires Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code

# Trust GitHub's SSH host keys system-wide so `git push` over SSH works without
# an interactive prompt. Fingerprints are verified against the values published
# at https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
RUN set -eu; \
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com > /etc/ssh/ssh_known_hosts.github; \
    expected="SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"; \
    for fp in $expected; do \
        ssh-keygen -lf /etc/ssh/ssh_known_hosts.github | grep -qF "$fp" \
            || { echo "github.com host key fingerprint $fp not found"; exit 1; }; \
    done; \
    cat /etc/ssh/ssh_known_hosts.github >> /etc/ssh/ssh_known_hosts; \
    rm /etc/ssh/ssh_known_hosts.github

# Pre-install gems so postCreate bundle install in the workspace is a no-op.
# The gemspec's Dir["lib/**/*.rb"] resolves to [] here; that's fine for
# dependency resolution.
COPY Gemfile dcb_event_store.gemspec /tmp/bundle-prep/
RUN cd /tmp/bundle-prep \
    && bundle lock --add-platform ruby \
    && bundle install \
    && cd / \
    && rm -rf /tmp/bundle-prep \
    && chown -R vscode:vscode /home/vscode/.bundle
