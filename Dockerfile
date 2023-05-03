FROM alpine:3.7

LABEL maintainer="Alexey Ivanov <lexa.ivanov@gmail.com>" \
	org.label-schema.docker.dockerfile="./3.4/Dockerfile" \
	org.label-schema.license="MIT" \
	org.label-schema.name="redmine-alpine" \
	org.label-schema.vcs-type="Git" \
	org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
        org.label-schema.version="3.4"

ENV BRANCH_NAME=3.4-stable \
        RAILS_ENV=production

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
                tini \
                su-exec \
                bash \
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
                curl \
                git \
        && echo 'gem: --no-document' > /etc/gemrc \
        && gem i rubygems-update -v '<3' \
        && update_rubygems \
	&& git clone -b ${BRANCH_NAME} https://github.com/redmine/redmine.git . \
        && rm -rf files/delete.me log/delete.me .git test\
        && mkdir -p tmp/pdf public/plugin_assets \
        && chown -R redmine:redmine ./\
	&& for adapter in mysql2 sqlite3; do \
		echo "$RAILS_ENV:" > ./config/database.yml; \
		echo "  adapter: $adapter" >> ./config/database.yml; \
		bundle install --without development test; \
	done \
	&& rm ./config/database.yml \
	&& rm -rf /root/* `gem env gemdir`/cache \
        && apk --purge del .build-deps

VOLUME /usr/src/redmine/files

COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 3000
CMD ["rails", "server", "-b", "0.0.0.0"]
