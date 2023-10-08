# Extra small Redmine container based on Alpine linux

![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=5.0)

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also it fast web server Unicorn built-in for production usage.

If you need another database or web server or even some scm support feel free to inherit these images from [Github](https://github.com/inspired-geek/redmine-alpine/pkgs/container/redmine-alpine).

## Usage

Test run:

```(shell)
    docker run -d -p 8080:8080 ghcr.io/inspired-geek/redmine-alpine:5.0
```
