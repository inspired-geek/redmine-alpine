FROM inspiredgeek/redmine-alpine:latest

LABEL maintainer="Alexey Ivanov <lexa.ivanov@gmail.com>" \
	org.label-schema.docker.dockerfile="./latest/unicorn/Dockerfile" \
        org.label-schema.license="MIT" \
        org.label-schema.name="redmine-alpine" \
        org.label-schema.vcs-type="Git" \
        org.label-schema.vcs-url="https://github.com/inspired-geek/redmine-alpine" \
        org.label-schema.version="latest-unicorn"

USER root

RUN apk add --no-cache --virtual .build-deps \
    ruby-dev \
    build-base \
    linux-headers \
  && gem install unicorn \
  && apk --purge del .build-deps \ 
  && chgrp -R 0 /usr/src/redmine \
  && chmod -R g=u /usr/src/redmine

USER 10001

COPY unicorn.conf.rb /usr/src/redmine/

CMD ["unicorn_rails", "-c", "/usr/src/redmine/unicorn.conf.rb", "-E", "production"]
