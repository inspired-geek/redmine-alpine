FROM alpine:latest

LABEL maintainer="Alexey Ivanov <lexa.ivanov@gmail.com>" \
  org.label-schema.docker.dockerfile="./Dockerfile" \
  org.label-schema.license="MIT" \
  org.label-schema.name="redmine-alpine" \
  org.label-schema.vcs-type="Git" \
  org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
  org.label-schema.version="latest"

ENV BRANCH_NAME=master \
  RAILS_ENV=production \
  REDMINE_SECRET_KEY_BASE=secret \
  DB_ADAPTER=sqlite3 \
  DB_NAME=/tmp/redmine.db

WORKDIR /usr/src/redmine

RUN addgroup -S redmine \
  && adduser -S -G redmine redmine \
  && apk --no-cache add --virtual .run-deps \
    mariadb-client-libs \
    sqlite-libs \
    imagemagick6 \
    tzdata \
    ruby \
    ruby-bigdecimal \
    ruby-bundler \
    ruby-json \
  && apk --no-cache add --virtual .build-deps \
    build-base \
    ruby-dev \
    libxslt-dev \
    imagemagick6-dev \
    mariadb-dev \
    sqlite-dev \
    linux-headers \
    patch \
    coreutils \
  && echo 'gem: --no-document' > /etc/gemrc \
  && gem update --system \
  && wget https://github.com/redmine/redmine/archive/master.tar.gz \
  && tar zxf master.tar.gz --strip-components=1 \
  && rm -rf master.tar.gz files/delete.me log/delete.me test\
  && mkdir -p tmp/pdf public/plugin_assets \
  && for adapter in mysql2 sqlite3; do \
    echo "$RAILS_ENV:" > ./config/database.yml; \
    echo "  adapter: $adapter" >> ./config/database.yml; \
    bundle install --without development test; \
  done \
  && rm ./config/database.yml \
  && rm -rf /root/* `gem env gemdir`/cache \
  && apk --purge del .build-deps 

COPY config/* ./config/
RUN chown -R redmine:redmine ./

USER redmine
VOLUME /usr/src/redmine/files

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
