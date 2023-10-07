# Extra small Redmine container based on Alpine linux

![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=3.4-ci&label=base+image+size)
![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=3.4-ci-unicorn&label=unicorn+image+size)

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also there is image with fast web server Unicorn for production usage.

If you need another database or web server or even some scm support feel free to inherit these images from [Github](https://github.com/inspired-geek/redmine-alpine/pkgs/container/redmine-alpine).

## Usage

Test run:

```bash
docker run -d -p 3000:3000 ghcr.io/inspired-geek/redmine-alpine:3.4
```

More close to production run with unicorn:

```bash
docker run -d -p 8080:8080 -v redmine-files:/usr/src/redmine/files ghcr.io/inspired-geek/redmine-alpine:3.4-unicorn
```
