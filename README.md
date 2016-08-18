Redmine container based on Alpine linux
=======================================

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.

### Usage

Test run:

    docker run -d -p 3000:3000 inspiredgeek/redmine-alpine

More close to production run with unicorn:

    docker run -d -p 8080:8080 -v redmine-files:/usr/src/redmine/files inspiredgeek/redmine-alpine:unicorn

