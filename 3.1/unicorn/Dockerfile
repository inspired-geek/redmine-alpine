FROM inspiredgeek/redmine-alpine:3.1
MAINTAINER Alexey Ivanov <lexa.ivanov@gmail.com>

RUN apk add --no-cache --virtual .build-deps \
		ruby-dev \
		build-base \
		linux-headers \
	&& gem install unicorn \
	&& apk --purge del .build-deps

CMD ["unicorn", "/usr/src/redmine/config.ru"]
