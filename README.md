# Extra small Redmine container based on Alpine linux

![Docker Image Size (tag)](https://img.shields.io/docker/image-size/inspiredgeek/redmine-alpine/3.4?style=for-the-badge)

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also there is image with fast web server Unicorn for production usage.

If you need another database or web server or even some scm support feel free to inherit these images from [Docker hub](https://hub.docker.com/r/inspiredgeek/redmine-alpine/).

## Usage

Test run:

```bash
docker run -d -p 3000:3000 inspiredgeek/redmine-alpine:3.4
```

More close to production run with unicorn:

```bash
docker run -d -p 8080:8080 -v redmine-files:/usr/src/redmine/files inspiredgeek/redmine-alpine:3.4-unicorn
```
