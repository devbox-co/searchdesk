FROM ruby:4.0.10-slim-trixie AS base
ARG RUBYGEMS_VERSION=4.1.0
RUN gem update --system "$RUBYGEMS_VERSION" --no-document && bundle --version

FROM base AS build
ENV BUNDLE_PATH=/usr/local/bundle BUNDLE_DEPLOYMENT=1
WORKDIR /app
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential libpq-dev libyaml-dev pkg-config && rm -rf /var/lib/apt/lists/*
COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

FROM base
ENV RAILS_ENV=production BUNDLE_PATH=/usr/local/bundle BUNDLE_DEPLOYMENT=1 RAILS_LOG_TO_STDOUT=true
WORKDIR /app
RUN apt-get update -qq && apt-get install --no-install-recommends -y libpq5 ca-certificates && rm -rf /var/lib/apt/lists/* && groupadd --gid 10001 rails && useradd --uid 10001 --gid rails --create-home rails
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails . .
RUN mkdir -p tmp/pids tmp/mail log public/assets && chown -R rails:rails tmp log public/assets
USER rails
RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
