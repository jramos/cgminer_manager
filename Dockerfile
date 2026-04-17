# syntax=docker/dockerfile:1

FROM ruby:4.0-slim AS builder

WORKDIR /app
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential git && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock cgminer_manager.gemspec ./
COPY lib/cgminer_manager/version.rb lib/cgminer_manager/version.rb
RUN bundle config set --local deployment 'true' \
 && bundle config set --local without 'development test' \
 && bundle install -j 1

COPY . .

FROM ruby:4.0-slim

WORKDIR /app
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    tzdata && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT='development test'
EXPOSE 3000

ENTRYPOINT ["bundle", "exec", "bin/cgminer_manager"]
CMD ["run"]
