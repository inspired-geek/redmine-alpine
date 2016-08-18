FROM inspiredgeek/redmine-alpine:3.1
MAINTAINER Alexey Ivanov <lexa.ivanov@gmail.com>

LABEL org.label-schema.docker.dockerfile="./3.1/unicorn/Dockerfile" \
        org.label-schema.license="MIT" \
        org.label-schema.name="redmine-alpine" \
        org.label-schema.vcs-type="Git" \
        org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
        org.label-schema.version="3.1-unicorn"

RUN apk add --no-cache --virtual .build-deps \
		ruby-dev \
		build-base \
		linux-headers \
	&& gem install unicorn \
	&& apk --purge del .build-deps

CMD ["unicorn", "/usr/src/redmine/config.ru"]
