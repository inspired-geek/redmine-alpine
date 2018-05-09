FROM inspiredgeek/redmine-alpine:3.2

LABEL maintainer="Alexey Ivanov <lexa.ivanov@gmail.com>" \
	org.label-schema.docker.dockerfile="./3.2/unicorn/Dockerfile" \
        org.label-schema.license="MIT" \
        org.label-schema.name="redmine-alpine" \
        org.label-schema.vcs-type="Git" \
        org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
        org.label-schema.version="3.2-unicorn"

RUN apk --no-cache add --upgrade \
        --virtual .build-deps \
		ruby-dev \
		build-base \
		linux-headers \
	&& gem install unicorn \
	&& apk --purge del .build-deps

COPY unicorn.conf.rb /usr/src/redmine/

CMD ["unicorn_rails", "-c", "/usr/src/redmine/unicorn.conf.rb", "-E", "production"]
