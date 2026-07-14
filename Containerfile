ARG SOURCE_BASE
ARG BUILDER_BASE
ARG RUNTIME_BASE

FROM ${SOURCE_BASE} AS helpers

COPY scripts/apk-add scripts/gemfile-canonicalize \
  scripts/runtime-cleanup scripts/runtime-verify /usr/local/bin/

FROM ${SOURCE_BASE} AS source

ARG SOURCE_URL
ARG SOURCE_SHA256
ARG SOURCE_DATE_EPOCH
ARG BUNDLER_GEM_SHA256
ARG BUNDLER_VERSION
ARG MARIADB_CONNECTOR_SOURCE_SHA256
ARG MARIADB_CONNECTOR_SOURCE_URL

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  /run/redmine-tools/apk-add ca-certificates coreutils curl tar; \
  mkdir -p /opt/mariadb-connector-source /opt/redmine-source; \
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 300 \
    --output /tmp/redmine.tar.gz \
    "$SOURCE_URL"; \
  echo "$SOURCE_SHA256  /tmp/redmine.tar.gz" | sha256sum -c -; \
  curl \
    --fail-with-body \
    --silent \
    --show-error \
    --location \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 300 \
    --output /tmp/bundler.gem \
    "https://rubygems.org/downloads/bundler-${BUNDLER_VERSION}.gem"; \
  echo "$BUNDLER_GEM_SHA256  /tmp/bundler.gem" | sha256sum -c -; \
  mv /tmp/bundler.gem /opt/bundler.gem; \
  tar -xzf /tmp/redmine.tar.gz \
    --strip-components=1 \
    --directory /opt/redmine-source; \
  if [ -n "$MARIADB_CONNECTOR_SOURCE_URL" ]; then \
    test -n "$MARIADB_CONNECTOR_SOURCE_SHA256"; \
    curl \
      --fail-with-body \
      --silent \
      --show-error \
      --location \
      --retry 3 \
      --retry-all-errors \
      --connect-timeout 10 \
      --max-time 300 \
      --output /tmp/mariadb-connector.tar.gz \
      "$MARIADB_CONNECTOR_SOURCE_URL"; \
    echo "$MARIADB_CONNECTOR_SOURCE_SHA256  /tmp/mariadb-connector.tar.gz" | \
      sha256sum -c -; \
    tar -xzf /tmp/mariadb-connector.tar.gz \
      --strip-components=1 \
      --directory /opt/mariadb-connector-source; \
  else \
    test -z "$MARIADB_CONNECTOR_SOURCE_SHA256"; \
  fi; \
  rm -f /tmp/mariadb-connector.tar.gz /tmp/redmine.tar.gz; \
  find /opt/redmine-source -exec \
    touch -h -d "@$SOURCE_DATE_EPOCH" {} +

FROM ${BUILDER_BASE} AS builder

ARG BUILD_PACKAGES
ARG BUNDLER_VERSION
ARG EXPECTED_RUBY_VERSION
ARG FORCE_RUBY_PLATFORM
ARG GEMFILE_LOCAL_BASE64
ARG MARIADB_CONNECTOR_SOURCE_SHA256
ARG MARIADB_CONNECTOR_SOURCE_URL
ARG MARIADB_CONNECTOR_VERSION
ARG PUMA_VERSION
ARG RUNTIME_PACKAGES
ARG RUNTIME_CLEANUP_KEEP_PATHS
ARG SOURCE_DATE_EPOCH

ENV BUNDLE_SILENCE_ROOT_WARNING=1 \
  BUNDLE_WITHOUT=development:test \
  GEM_HOME=/usr/local/bundle \
  GEM_PATH=/usr/local/bundle \
  PATH=/usr/local/bundle/bin:${PATH} \
  PUMA_DISABLE_SSL=1

WORKDIR /usr/src/redmine

COPY --from=source /opt/redmine-source/ /usr/src/redmine/
COPY --from=source /opt/mariadb-connector-source/ /tmp/mariadb-connector-source/
COPY --from=source /opt/bundler.gem /tmp/bundler.gem
RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  /run/redmine-tools/apk-add $RUNTIME_PACKAGES; \
  /run/redmine-tools/apk-add --virtual .build-deps $BUILD_PACKAGES; \
  test "$(ruby -e 'print RUBY_VERSION')" = "$EXPECTED_RUBY_VERSION"; \
  bundle_jobs=$(awk '/^processor/ { count += 1 } END { print count }' /proc/cpuinfo); \
  [ "$bundle_jobs" -ge 1 ] || bundle_jobs=2; \
  [ "$bundle_jobs" -le 10 ] || bundle_jobs=10; \
  mkdir -p /opt/mariadb-connector-runtime; \
  if [ -n "$MARIADB_CONNECTOR_VERSION" ]; then \
    test -n "$MARIADB_CONNECTOR_SOURCE_URL"; \
    test -n "$MARIADB_CONNECTOR_SOURCE_SHA256"; \
    cmake -S /tmp/mariadb-connector-source \
      -B /tmp/mariadb-connector-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/mariadb-connector \
      -DINSTALL_LAYOUT=DEFAULT \
      -DWITH_CURL=OFF \
      -DWITH_EXTERNAL_ZLIB=ON \
      -DWITH_SSL=OPENSSL \
      -DWITH_UNIT_TESTS=OFF; \
    cmake --build /tmp/mariadb-connector-build --parallel "$bundle_jobs"; \
    cmake --install /tmp/mariadb-connector-build; \
    test "$(/opt/mariadb-connector/bin/mariadb_config --cc_version)" = \
      "$MARIADB_CONNECTOR_VERSION"; \
    mkdir -p /opt/mariadb-connector-runtime/lib/mariadb; \
    cp -a /opt/mariadb-connector/lib/mariadb/libmariadb.so.3* \
      /opt/mariadb-connector-runtime/lib/mariadb/; \
    cp -a /opt/mariadb-connector/lib/mariadb/plugin \
      /opt/mariadb-connector-runtime/lib/mariadb/; \
    test -e /opt/mariadb-connector-runtime/lib/mariadb/libmariadb.so.3; \
    test -d /opt/mariadb-connector-runtime/lib/mariadb/plugin; \
  else \
    test -z "$MARIADB_CONNECTOR_SOURCE_URL"; \
    test -z "$MARIADB_CONNECTOR_SOURCE_SHA256"; \
  fi

RUN set -eux; \
  bundle_jobs=$(awk '/^processor/ { count += 1 } END { print count }' /proc/cpuinfo); \
  [ "$bundle_jobs" -ge 1 ] || bundle_jobs=2; \
  [ "$bundle_jobs" -le 10 ] || bundle_jobs=10; \
  if [ -n "$MARIADB_CONNECTOR_VERSION" ]; then \
    export BUNDLE_BUILD__MYSQL2=--with-mysql-config=/opt/mariadb-connector/bin/mariadb_config; \
    export LD_LIBRARY_PATH=/opt/mariadb-connector/lib/mariadb; \
  fi; \
  gem install --local --no-document /tmp/bundler.gem; \
  rm -f /tmp/bundler.gem; \
  sed -i '/^[[:space:]]*gem .*puma/d' Gemfile; \
  printf '%s' "$GEMFILE_LOCAL_BASE64" | base64 -d > Gemfile.local; \
  case "$FORCE_RUBY_PLATFORM" in \
    true) export BUNDLE_FORCE_RUBY_PLATFORM=1 ;; \
    false) unset BUNDLE_FORCE_RUBY_PLATFORM ;; \
    *) printf 'invalid FORCE_RUBY_PLATFORM: %s\n' "$FORCE_RUBY_PLATFORM" >&2; exit 64 ;; \
  esac; \
  export MAKEFLAGS="-j$bundle_jobs"; \
  bundle install --jobs "$bundle_jobs"; \
  mkdir -p \
    files \
    log \
    plugins \
    public/assets \
    public/plugin_assets \
    public/themes \
    sqlite \
    tmp/pdf \
    tmp/pids

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  /run/redmine-tools/gemfile-canonicalize Gemfile Gemfile.local; \
  bundle check

COPY config/production.append.rb /tmp/redmine-alpine-production.rb

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  cat /tmp/redmine-alpine-production.rb >> config/environments/production.rb; \
  rm -f /tmp/redmine-alpine-production.rb; \
  RUNTIME_CLEANUP_KEEP_PATHS="$RUNTIME_CLEANUP_KEEP_PATHS" \
    /run/redmine-tools/runtime-cleanup "$GEM_HOME" /usr/src/redmine /usr/local; \
  scanelf \
    --nobanner \
    --format '%F' \
    --recursive /usr/local \
    | while IFS= read -r target; do \
        case $target in \
          "$GEM_HOME"/*) continue ;; \
        esac; \
        strip --strip-unneeded "$target"; \
      done; \
  rm -f "$GEM_HOME"/gems/rbpdf-font-*/lib/fonts/ttf2ufm/ttf2ufm; \
  scanelf \
    --needed \
    --nobanner \
    --format '%n#p' \
    --recursive /usr/local /opt/mariadb-connector-runtime \
    | tr ',' '\n' \
    | sort -u \
    | awk \
      '$1 == "libc.so" { next } \
       system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } \
       system("[ -e /opt/mariadb-connector-runtime/lib/mariadb/" $1 " ]") == 0 { next } \
       { print "so:" $1 }' \
    > /tmp/runtime-deps; \
  find /opt/mariadb-connector-runtime /usr/local /usr/src/redmine -exec \
    touch -h -d "@$SOURCE_DATE_EPOCH" {} +; \
  chmod -R go-w /usr/local /usr/src/redmine

FROM ${RUNTIME_BASE} AS runtime

ARG BUILD_PACKAGES
ARG BUNDLER_VERSION
ARG EXPECTED_REDMINE_VERSION
ARG EXPECTED_RUBY_VERSION
ARG FEATURE_PACKAGES
ARG MARIADB_CONNECTOR_VERSION
ARG PUMA_VERSION
ARG RUNTIME_CLEANUP_KEEP_PATHS
ARG RUNTIME_COMMANDS
ARG RUNTIME_PACKAGES
ARG RUNTIME_PATHS
ARG RUNTIME_REQUIRES

ENV BUNDLE_APP_CONFIG=/usr/local/bundle \
  BUNDLE_SILENCE_ROOT_WARNING=1 \
  BUNDLE_WITHOUT=development:test \
  DB_ADAPTER=sqlite3 \
  GEM_HOME=/usr/local/bundle \
  GEM_PATH=/usr/local/bundle \
  HOME=/home/redmine \
  LANG=C.UTF-8 \
  LD_LIBRARY_PATH=/opt/mariadb-connector/lib/mariadb \
  PATH=/usr/local/bundle/bin:${PATH} \
  RAILS_ENV=production \
  RAILS_LOG_TO_STDOUT=true \
  RUBY_VERSION=$EXPECTED_RUBY_VERSION \
  RUBYOPT=-rlogger \
  REDMINE_VERSION=$EXPECTED_REDMINE_VERSION

WORKDIR /usr/src/redmine

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  adduser -D -H -u 1001 -G root redmine; \
  mkdir -p "$HOME"; \
  /run/redmine-tools/apk-add $FEATURE_PACKAGES $RUNTIME_PACKAGES; \
  if ! command -v convert >/dev/null 2>&1; then \
    imagemagick6_convert=$(command -v convert-6); \
    ln -s "$imagemagick6_convert" /usr/local/bin/convert; \
  fi; \
  if ! command -v identify >/dev/null 2>&1; then \
    imagemagick6_identify=$(command -v identify-6); \
    ln -s "$imagemagick6_identify" /usr/local/bin/identify; \
  fi

COPY --from=builder /tmp/runtime-deps /tmp/runtime-deps
COPY --from=builder /opt/mariadb-connector-runtime/ /opt/mariadb-connector/

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  if [ -s /tmp/runtime-deps ]; then \
    /run/redmine-tools/apk-add --virtual .redmine-rundeps \
      $(cat /tmp/runtime-deps); \
  fi; \
  rm -f /tmp/runtime-deps

COPY --from=builder /usr/local/ /usr/local/
COPY --from=builder /usr/src/redmine/ /usr/src/redmine/
COPY config/database.yml config/secrets.yml config/puma.rb \
  /usr/src/redmine/config/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint

RUN --mount=type=bind,from=helpers,source=/usr/local/bin,target=/run/redmine-tools,ro \
  set -eux; \
  chmod go-w /usr/local /usr/src/redmine; \
  chown -R 1001:0 \
    "$HOME" files log plugins public/assets public/plugin_assets \
    public/themes sqlite tmp; \
  chmod -R g=u \
    "$HOME" files log plugins public/assets public/plugin_assets \
    public/themes sqlite tmp; \
  export \
    BUILD_PACKAGES \
    EXPECTED_REDMINE_VERSION \
    EXPECTED_RUBY_VERSION \
    MARIADB_CONNECTOR_VERSION \
    FEATURE_PACKAGES \
    RUNTIME_CLEANUP_KEEP_PATHS \
    RUNTIME_COMMANDS \
    RUNTIME_PACKAGES \
    RUNTIME_PATHS \
    RUNTIME_REQUIRES; \
  export EXPECTED_BUNDLER_VERSION="$BUNDLER_VERSION"; \
  export EXPECTED_MARIADB_CONNECTOR_VERSION="$MARIADB_CONNECTOR_VERSION"; \
  export EXPECTED_PUMA_VERSION="$PUMA_VERSION"; \
  /run/redmine-tools/apk-add --virtual .verify-deps pax-utils; \
  /run/redmine-tools/runtime-verify elf; \
  apk del --no-network .verify-deps; \
  /run/redmine-tools/runtime-verify contract

ARG BUILD_DATE
ARG OCI_AUTHORS
ARG OCI_DESCRIPTION
ARG OCI_DOCUMENTATION
ARG OCI_LICENSES
ARG OCI_SOURCE
ARG OCI_TITLE
ARG OCI_URL
ARG OCI_VERSION
ARG VCS_REF

LABEL org.opencontainers.image.authors="$OCI_AUTHORS" \
  org.opencontainers.image.created="$BUILD_DATE" \
  org.opencontainers.image.description="$OCI_DESCRIPTION" \
  org.opencontainers.image.documentation="$OCI_DOCUMENTATION" \
  org.opencontainers.image.licenses="$OCI_LICENSES" \
  org.opencontainers.image.revision="$VCS_REF" \
  org.opencontainers.image.source="$OCI_SOURCE" \
  org.opencontainers.image.title="$OCI_TITLE" \
  org.opencontainers.image.url="$OCI_URL" \
  org.opencontainers.image.version="$OCI_VERSION"

USER 1001

VOLUME ["/usr/src/redmine/files", "/usr/src/redmine/plugins", "/usr/src/redmine/public/plugin_assets", "/usr/src/redmine/public/themes", "/usr/src/redmine/sqlite"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
STOPSIGNAL SIGTERM
EXPOSE 8080
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
