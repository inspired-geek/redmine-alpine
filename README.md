# Redmine on Alpine

This repository publishes ten Redmine profiles and all fourteen managed tags
as versions of one GitHub Container Registry package:
`ghcr.io/inspired-geek/redmine-alpine`.

Every profile follows the same contract: one root `Containerfile`, one catalog,
one mandatory CI matrix, Puma, numeric UID 1001, port 8080, SQLite and
MySQL/MariaDB adapters, the same functional smoke tests, and the same verified
publication path. Compatibility profiles keep the Ruby and Alpine base needed
by their Redmine release; profiles that support the current base use Alpine
3.24. Profiles built from an official Ruby image copy only the cleaned,
stripped Ruby runtime into a pinned plain-Alpine final stage; package-Ruby
profiles use the same build graph without carrying a compiler toolchain.

## Image matrix

| Profile | Published tag(s) | Bundled Redmine | Ruby / Alpine compatibility base | Puma | Release status |
|---|---|---|---|---|---|
| `3.4` | `3.4` | 3.4.13 | Ruby 2.4.10 / Alpine 3.7 | 6.6.1 | Unsupported compatibility release |
| `4.0` | `4.0` | 4.0.9 | Ruby 2.6.8 / Alpine 3.11 | 6.6.1 | Unsupported compatibility release |
| `4.1` | `4.1` | 4.1.7 | Ruby 2.6.8 / Alpine 3.11 | 6.6.1 | Unsupported compatibility release |
| `4.2` | `4.2` | 4.2.11 | Ruby 2.7.8 / Alpine 3.14 | 6.6.1 | Unsupported compatibility release |
| `5.0` | `5.0` | 5.0.6 | Ruby 3.1.5 / Alpine 3.17 | 8.0.2 | Unsupported compatibility release |
| `trunk` | `trunk` | Resolved upstream development snapshot | Ruby 3.4.10 / Alpine 3.24 | 8.0.2 | Development snapshot |
| `5.1` | `5.1`, `5.1.13` | 5.1.13 | Ruby 3.2.11 / Alpine 3.23 | 8.0.2 | Unsupported compatibility release |
| `6.0` | `6.0`, `6.0.10` | 6.0.10 | Ruby 3.3.11 / Alpine 3.24 | 8.0.2 | Important security fixes only |
| `6.1` | `6.1`, `6.1.3` | 6.1.3 | Ruby 3.4.10 / Alpine 3.24 | 8.0.2 | Bug-fix and security support |
| `7.0` | `7.0`, `7.0.0` | 7.0.0 | Ruby 3.4.10 / Alpine 3.24 | 8.0.2 | Current stable release |

Series tags and `trunk` are moving aliases. Exact tags `5.1.13`, `6.0.10`,
`6.1.3`, and `7.0.0` are immutable after their first verified publication.
The older tag names remain available in the same package; the pipeline does not
invent patch aliases for them.

The machine-readable source of truth is
[`build/images.json`](build/images.json). It pins source checksums, base images,
Ruby, Bundler, Puma, compatibility gems, runtime packages, test inputs, tools,
tags, OCI metadata, compression policy, and measured size budgets.

## Pulling an image

Normal Docker and Podman clients can pull a tag directly:

~~~sh
docker pull ghcr.io/inspired-geek/redmine-alpine:7.0
~~~

Each tag is an OCI image index with two byte-equivalent runtime variants:

- gzip is first and remains the portable compatibility path;
- `zstd:chunked` is also published for clients that support seekable partial
  pulls.

The selected zstd level is 10. The pinned compressor maps level 10 and higher
numeric levels to the same best-compression class, so larger numbers do not
produce a smaller image. Reproducible benchmark evidence is recorded in
[`build/compression-benchmark.json`](build/compression-benchmark.json).

## GitHub Container Registry metadata

The root OCI index, both manifest descriptors, and the image configuration
carry the metadata needed by GitHub Container Registry. This includes
`org.opencontainers.image.source`, `org.opencontainers.image.description`,
`org.opencontainers.image.licenses`, version, revision, creation time,
documentation, title, URL, and author. The index annotations make the metadata
visible on each tag page instead of only inside a child manifest.

The source is always this repository and the bundled application license is
`GPL-2.0-or-later`. If an existing package has not yet been associated with the
repository, connect it once in the package settings; subsequent workflow runs
preserve that association and publish all tags to the same package.

## Quick start with persistent SQLite

SQLite is useful for evaluation and small installations. MariaDB is the safer
choice for a multi-user production deployment.

~~~sh
export SECRET_KEY_BASE="$(openssl rand -hex 32)"
docker volume create redmine-files
docker volume create redmine-sqlite

docker run -d \
  --name redmine \
  -p 8080:8080 \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -v redmine-files:/usr/src/redmine/files \
  -v redmine-sqlite:/usr/src/redmine/sqlite \
  ghcr.io/inspired-geek/redmine-alpine:7.0
~~~

Open <http://localhost:8080/login>. Reuse the same secret and volumes whenever
the container is replaced.

## MariaDB with Compose

The checked-in Compose file uses the `7.0` image, persists files, plugins,
plugin assets, themes, and database data, and waits for a patch-pinned MariaDB
image to become healthy.

~~~sh
export SECRET_KEY_BASE="$(openssl rand -hex 32)"
export DB_PASSWORD="$(openssl rand -hex 24)"
docker compose up -d
~~~

Use `docker compose logs -f redmine` to observe migrations and startup.

## Runtime configuration

| Variable | Default | Meaning |
|---|---|---|
| `SECRET_KEY_BASE` | required | Preferred Rails signing and encryption secret |
| `REDMINE_SECRET_KEY_BASE` | unset | Compatibility alias, used only when `SECRET_KEY_BASE` is empty |
| `DB_ADAPTER` | `sqlite3` | `sqlite3` or `mysql2` |
| `DB_HOST` | `db` for MySQL | Database host |
| `DB_PORT` | `3306` for MySQL | Positive database port |
| `DB_USER` | `redmine` for MySQL | Database user |
| `DB_PASSWORD` | empty | Database password |
| `DB_NAME` | adapter-specific | SQLite file or MySQL database name |
| `PORT` | `8080` | Puma TCP port |
| `RAILS_MAX_THREADS` | `5` | Puma threads and Active Record pool per process |
| `WEB_CONCURRENCY` | `1` | Puma process count; preload is enabled above one |
| `REDMINE_NO_DB_MIGRATE` | empty | Any non-empty value disables automatic migrations |
| `REDMINE_DB_MIGRATE_RETRIES` | `30` | Maximum complete migration attempts |
| `REDMINE_DB_MIGRATE_DELAY` | `2` | Seconds between migration attempts |

With `WEB_CONCURRENCY=N`, budget up to `N * RAILS_MAX_THREADS` database
connections. For SQLite, `DB_NAME` defaults to
`/usr/src/redmine/sqlite/redmine.db`. MySQL/MariaDB uses `utf8mb4` and
`READ-COMMITTED` transaction isolation.

The image contains no default application secret. Startup fails before
database access if neither supported secret variable is set. Keep the secret
stable during normal replacements so existing encrypted and signed data
remains valid.

## Migrations and custom commands

For the default `bundle exec puma -C config/puma.rb` command, the entrypoint
runs core migrations followed by plugin migrations. It retries the complete
pair using the bounded policy above. Signals received during migration are
forwarded to the active child process.

Commands such as `sh`, `ruby`, and `rake` do not migrate implicitly. Set
`REDMINE_NO_DB_MIGRATE=1` when a deployment uses a separate migration job.
Multiple replicas still need deployment-level migration coordination.

## Installing plugins

Plugin gems need the same compiler and development headers as Redmine itself.
Put plugin source under the repository's `plugins/<name>/` directory before
running `scripts/image-build`; every plugin `Gemfile` or `PluginGemfile` is then
resolved and compiled in the common builder stage. Redmine core and the gem
tree remain root-owned and read-only; `plugins/` keeps its documented writable
UID 1001/group 0 data-path permissions for existing deployments.

Runtime-mounted plugins remain compatible when all their dependencies are
already present in the image. Before migrations, the entrypoint resolves plugin
Gemfiles with `bundle install --local` into a temporary writable lockfile; it
does not use the network or modify the root-owned application lockfile. The
same temporary bundle definition is used for migrations and Puma. A missing
gem exits immediately with a build instruction instead of being retried as
though the database were temporarily unavailable.

A volume mounted at `/usr/src/redmine/plugins` replaces the plugin directory
from the image. Keep that volume synchronized with the plugin revisions used
during the build, and review or recreate it when plugin code changes. Plugin
assets generated by Redmine remain persistent in `public/plugin_assets`.

## Persistent paths and permissions

All profiles declare the same persistent paths:

- `/usr/src/redmine/files`
- `/usr/src/redmine/plugins`
- `/usr/src/redmine/public/plugin_assets`
- `/usr/src/redmine/public/themes`
- `/usr/src/redmine/sqlite`

Core application assets in `/usr/src/redmine/public/assets` belong to the image
and are intentionally not a persistent volume. Named volumes inherit image
ownership on first use. Bind-mounted directories must be writable by UID 1001
or group 0; arbitrary UIDs in group 0 are also supported.

## Migrating existing deployments

The `3.4`, `4.0`, `4.1`, `4.2`, `5.0`, and `trunk` tags now use the same Puma
runtime as every other tag. When replacing previous Unicorn-based images:

1. Back up the database and all persistent paths.
2. Set a stable `SECRET_KEY_BASE` (the old `REDMINE_SECRET_KEY_BASE` name remains
   a compatibility alias).
3. Move any SQLite database previously kept in a temporary container path to
   `/usr/src/redmine/sqlite/redmine.db`, or configure the external database
   variables explicitly.
4. Keep port 8080 and mount the paths listed above.
5. Test the exact profile against a copy of production data before advancing a
   moving tag. Follow Redmine's supported intermediate upgrade sequence when
   crossing release families.

The first default startup performs core and plugin migrations. A deployment
that already owns migration ordering should set `REDMINE_NO_DB_MIGRATE=1` and
run its migration job before starting application replicas.

## Build and smoke test

Local builds use the single root `Containerfile` through the catalog-aware
driver. Docker or Podman must be running; the pinned build toolchain is launched
inside it.

~~~sh
scripts/image-catalog validate

profile=7.0
output="artifacts/images/$profile/linux-amd64"
image="localhost/redmine-alpine:${profile}-local"

scripts/image-build "$profile" \
  --platform linux/amd64 \
  --tag "$image" \
  --output-dir "$output" \
  --revision "$(git rev-parse HEAD)" \
  --no-cache

image_id="$(podman pull --quiet "oci-archive:$output/rootfs.oci.tar")"
podman tag "$image_id" "$image"

tests/smoke-image.sh "$profile" "$image" sqlite
tests/smoke-image.sh "$profile" "$image" mariadb
~~~

Set `CONTAINER_ENGINE=docker` for the smoke tests when using Docker. The CI
matrix performs both database smokes for every profile, produces gzip and
`zstd:chunked` variants, verifies size budgets and OCI metadata, uploads the
tested index as an artifact, and only then publishes it.

## License

Repository wrapper code is MIT-licensed. Every image bundles Redmine, which is
GPL-2.0-or-later; image metadata therefore records `GPL-2.0-or-later` for the
bundled application.
