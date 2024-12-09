FROM ruby:3.3-slim

# Install system dependencies including exiftool and vips
RUN apt-get update && apt-get install -y \
  build-essential \
  ruby-trello \
  sqlite3 \
  git \
  && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Create a non-root user
RUN useradd -m appuser && \
  chown -R appuser:appuser /app && \
  chown -R appuser:appuser /usr/local/bundle

USER appuser

# Set environment variable for Bundler
ENV BUNDLE_GEMFILE=/app/Gemfile

CMD ["/bin/bash"]