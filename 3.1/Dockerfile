FROM alpine:3.3
MAINTAINER Alexey Ivanov <lexa.ivanov@gmail.com>

LABEL org.label-schema.docker.dockerfile="./3.1/Dockerfile" \
        org.label-schema.license="MIT" \
        org.label-schema.name="redmine-alpine" \
        org.label-schema.vcs-type="Git" \
        org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
        org.label-schema.version="3.1"

ENV BRANCH_NAME=3.1-stable \
        RAILS_ENV=production

WORKDIR /usr/src/redmine

RUN addgroup -S redmine \
        && adduser -S -G redmine redmine \
	&& apk --no-cache add --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ --virtual .run-deps \
                mariadb-libs \
                imagemagick \
                git \
                mercurial \
                tzdata \
                'ruby<2.4' \
		ruby-bigdecimal \
		ruby-bundler \
		ruby-rake \
		ruby-io-console \
                tini \
                su-exec \
		bash \
        && apk --no-cache add --virtual .build-deps \
                build-base \
                ruby-dev \
                libxslt-dev \
                imagemagick-dev \
                sqlite-dev \
		mariadb-dev \
		postgresql-dev \ 
                linux-headers \
                patch \
                coreutils \
                curl \
        && echo 'gem: --no-document' > /etc/gemrc \
        && gem update --system \
	&& git clone -b ${BRANCH_NAME} https://github.com/redmine/redmine.git . \
        && rm -rf files/delete.me log/delete.me .git test\
        && mkdir -p tmp/pdf public/plugin_assets \
        && chown -R redmine:redmine ./\
	&& for adapter in mysql2 postgresql sqlite3; do \
		echo "$RAILS_ENV:" > ./config/database.yml; \
		echo "  adapter: $adapter" >> ./config/database.yml; \
		bundle install --without development test; \
	done \
        && bundle install --without development test \
	&& rm ./config/database.yml \
        && apk --purge del .build-deps

VOLUME /usr/src/redmine/files

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
