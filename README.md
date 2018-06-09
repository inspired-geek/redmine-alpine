Extra small Redmine container based on Alpine linux
=======================================

[![Docker Repository on Quay](https://quay.io/repository/inspired_geek/redmine-alpine/status "Docker Repository on Quay")](https://quay.io/repository/inspired_geek/redmine-alpine) [![](https://images.microbadger.com/badges/image/inspiredgeek/redmine-alpine.svg)](http://microbadger.com/images/inspiredgeek/redmine-alpine "Get your own image badge on microbadger.com")

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also there is image with fast web server Unicorn for production usage.

If you need another database or web server or even some scm support feel free to inherit these images from [Docker hub](https://hub.docker.com/r/inspiredgeek/redmine-alpine/).

### Usage

Test run:

    docker run -d -p 3000:3000 inspiredgeek/redmine-alpine

More close to production run with unicorn:

    docker run -d -p 8080:8080 -v redmine-files:/usr/src/redmine/files inspiredgeek/redmine-alpine:unicorn
