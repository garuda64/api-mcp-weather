# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t api_mcp_weather .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name api_mcp_weather api_mcp_weather

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.10
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems

# Disable Bundler frozen/deployment mode during build so Gemfile.lock can update
ENV BUNDLE_DEPLOYMENT="0"
RUN bundle config set frozen false

# Copy gem manifests first to leverage Docker layer caching and ensure lockfile updates
COPY Gemfile Gemfile.lock ./
COPY Gemfile Gemfile.lock vendor ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# Preserve the updated lockfile to override repository version later
RUN cp Gemfile.lock /tmp/Gemfile.lock.built

# Copy application code
COPY . .

# Removed bootsnap precompilation (bootsnap gem not used)

# Adjust binfiles to be executable on Linux
RUN chmod +x bin/* && \
    sed -i "s/\r$//g" bin/* && \
    sed -i 's/ruby\.exe$/ruby/' bin/*




# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
ENV BUNDLE_DEPLOYMENT="1"
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Override repository Gemfile.lock with the one generated during build
COPY --chown=rails:rails --from=build /tmp/Gemfile.lock.built /rails/Gemfile.lock

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Rails Puma directly, can be overwritten at runtime
EXPOSE 80
# Nota: el entrypoint autogenera un SECRET_KEY_BASE efímero si faltan secretos.
# Para producción real, provee RAILS_MASTER_KEY o SECRET_KEY_BASE mediante secretos.
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "80"]
