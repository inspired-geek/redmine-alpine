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
  DB_NAME=/tmp/redmine.db \
  HOME=/usr/src/redmine \
  GEM_HOME=/usr/src/redmine/.gem \
  GEM_PATH=/usr/src/redmine/.gem \
  PATH=$PATH:/usr/src/redmine/.gem/bin

WORKDIR /usr/src/redmine

RUN apk --no-cache add --virtual .run-deps \
    mariadb-client-libs \
    sqlite-libs \
    imagemagick6 \
    ruby \
  && apk --no-cache add --virtual .build-deps \
    build-base \
    ruby-dev \
    imagemagick6-dev \
    mariadb-dev \
    sqlite-dev \
  && echo 'gem: --no-document' > /etc/gemrc \
  && gem update --system \
  && wget https://github.com/redmine/redmine/archive/master.tar.gz \
  && tar zxf master.tar.gz --strip-components=1 \
  && rm -rf master.tar.gz files/delete.me log/delete.me test\
  && mkdir -p tmp/pdf public/plugin_assets \
  && gem install bundler mysql2 sqlite3 \
  && echo 'gem "json"' >> Gemfile \
  && echo 'gem "bigdecimal"' >> Gemfile \
  && echo 'gem "tzinfo-data"' >> Gemfile \
  && bundle install --without development test \
  && rm -rf .gem/cache \
  && apk --purge del .build-deps 

COPY config/* ./config/

RUN chgrp -R 0 /usr/src/redmine \
  && chmod -R g=u /usr/src/redmine

USER 10001
VOLUME /usr/src/redmine/files /usr/src/redmine/publib/plugin_assets /usr/src/redmine/plugins /usr/src/redmine/public/themes

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
