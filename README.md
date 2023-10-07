# Extra small Redmine container based on Alpine linux

![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=latest&label=base+image+size)
![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=unicorn&label=unicorn+image+size)

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also there is image with fast web server Unicorn for production usage.

If you need another database or web server or even some scm support feel free to inherit these images from [Github](https://github.com/inspired-geek/redmine-alpine/pkgs/container/redmine-alpine).

## Usage

Test run:

    docker run -d -p 3000:3000 inspiredgeek/redmine-alpine

More close to production run with unicorn:

    docker run -d -p 8080:8080 -v redmine-files:/usr/src/redmine/files inspiredgeek/redmine-alpine:unicorn
