# Extra small Redmine container image based on Alpine linux

![Docker Image Size (tag)](https://ghcr-badge.deta.dev/inspired-geek/redmine-alpine/size?tag=5.0)

It's been inspired by official [Redmine](https://hub.docker.com/_/redmine/) image but optimized in size.
Image has mysql and sqlite3 support built in.
Also it has embedded fast web server [Unicorn](https://yhbt.net/unicorn/README.html) for production usage.

Image runs as non-root user by default thus allow to use it in security restricted environments like [Red Hat OpenShift](https://openshift.com)

If you need another database or web server or even some scm support feel free to use these images from [Github](https://github.com/inspired-geek/redmine-alpine/pkgs/container/redmine-alpine) as your base image.

## Usage

Test run:

```(shell)
docker run -d -p 8080:8080 ghcr.io/inspired-geek/redmine-alpine:5.0
```

More complex example with docker-compose:

```(shell)
docker-compose up -d
```
