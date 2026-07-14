#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
metrics=$root/scripts/image-metrics
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  format=$1
  output=$2
  ruby -rjson -rdigest -rtime -rstringio -rzlib -rrubygems/package -e '
    format, output, catalog_path = ARGV
    profile = JSON.parse(File.read(catalog_path)).fetch("profiles").find do |candidate|
      candidate.fetch("id") == "3.4"
    end
    abort "profile fixture missing" unless profile

    created = Time.at(profile.dig("source", "source_date_epoch")).utc.iso8601
    labels = profile.fetch("oci").each_with_object({}) do |(key, value), result|
      result["org.opencontainers.image.#{key}"] = value
    end
    labels["org.opencontainers.image.created"] = created
    labels["org.opencontainers.image.revision"] = "e" * 40

    rootfs = "rootfs fixture\n" * 10
    diff_id = "sha256:" + Digest::SHA256.hexdigest(rootfs)
    config = JSON.generate(
      "architecture" => "amd64",
      "os" => "linux",
      "config" => {"Labels" => labels},
      "rootfs" => {"type" => "layers", "diff_ids" => [diff_id]}
    )
    config_digest = Digest::SHA256.hexdigest(config)

    if format == "gzip"
      buffer = StringIO.new
      gzip = Zlib::GzipWriter.new(buffer, Zlib::BEST_COMPRESSION)
      gzip.mtime = 0
      gzip.write(rootfs)
      gzip.close
      layer = buffer.string
      layer_descriptor = {
        "mediaType" => "application/vnd.oci.image.layer.v1.tar+gzip"
      }
    else
      layer = "zstd:chunked fixture payload\n"
      layer_descriptor = {
        "mediaType" => "application/vnd.oci.image.layer.v1.tar+zstd",
        "annotations" => {
          "io.github.containers.zstd-chunked.manifest-checksum" =>
            "sha256:" + ("a" * 64),
          "io.github.containers.zstd-chunked.manifest-position" => "1:2:3:1",
          "io.github.containers.zstd-chunked.tarsplit-position" => "4:5:6"
        }
      }
    end
    layer_digest = Digest::SHA256.hexdigest(layer)
    layer_descriptor["digest"] = "sha256:#{layer_digest}"
    layer_descriptor["size"] = layer.bytesize

    manifest = JSON.generate(
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "config" => {
        "mediaType" => "application/vnd.oci.image.config.v1+json",
        "digest" => "sha256:#{config_digest}",
        "size" => config.bytesize
      },
      "layers" => [layer_descriptor]
    )
    manifest_digest = Digest::SHA256.hexdigest(manifest)
    index = JSON.generate(
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.index.v1+json",
      "manifests" => [{
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "digest" => "sha256:#{manifest_digest}",
        "size" => manifest.bytesize,
        "annotations" => {"org.opencontainers.image.ref.name" => "3.4"}
      }]
    )
    files = {
      "blobs/sha256/#{config_digest}" => config,
      "blobs/sha256/#{layer_digest}" => layer,
      "blobs/sha256/#{manifest_digest}" => manifest,
      "index.json" => index,
      "oci-layout" => JSON.generate("imageLayoutVersion" => "1.0.0")
    }
    previous_epoch = ENV["SOURCE_DATE_EPOCH"]
    ENV["SOURCE_DATE_EPOCH"] = profile.dig("source", "source_date_epoch").to_s
    File.open(output, "wb") do |file|
      Gem::Package::TarWriter.new(file) do |tar|
        files.sort.each do |name, contents|
          tar.add_file_simple(name, 0o644, contents.bytesize) do |entry|
            entry.write(contents)
          end
        end
      end
    end
    ENV["SOURCE_DATE_EPOCH"] = previous_epoch
  ' "$format" "$output" "$root/build/images.json"
}

make_fixture gzip "$tmp/gzip.oci.tar"
make_fixture zstd-chunked "$tmp/zstd.oci.tar"
"$root/scripts/oci-index" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --output "$tmp/index.oci.tar" >/dev/null

[ -x "$metrics" ] || fail "missing executable scripts/image-metrics"

"$metrics" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --index-archive "$tmp/index.oci.tar" \
  --output "$tmp/metrics.json"
"$metrics" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --index-archive "$tmp/index.oci.tar" \
  --output "$tmp/metrics-again.json" \
  --baseline "$tmp/metrics.json" >/dev/null

cmp "$tmp/metrics.json" "$tmp/metrics-again.json" >/dev/null ||
  fail "normalized metrics are not reproducible"

ruby -rjson -rdigest -e '
  value = JSON.parse(File.read(ARGV.fetch(0)))
  abort "schema" unless value.fetch("schema_version") == 1
  abort "profile" unless value.fetch("profile") == "3.4"
  abort "platform" unless value.fetch("platform") == "linux/amd64"
  content = value.fetch("content")
  abort "rootfs bytes" unless content.fetch("rootfs_bytes") ==
    ("rootfs fixture\n" * 10).bytesize
  %w[config_digest gzip_manifest_digest zstd_chunked_manifest_digest index_digest].each do |key|
    abort key unless content.fetch(key).match?(/\Asha256:[0-9a-f]{64}\z/)
  end
  budgets = value.fetch("budgets")
  %w[rootfs_bytes gzip_bytes zstd_chunked_bytes].each do |key|
    abort "budget #{key}" unless budgets.fetch(key).fetch("actual") <=
      budgets.fetch(key).fetch("limit")
    abort "headroom #{key}" unless budgets.fetch(key).fetch("headroom") ==
      budgets.fetch(key).fetch("limit") - budgets.fetch(key).fetch("actual")
  end
  {
    "gzip" => ARGV.fetch(1),
    "zstd_chunked" => ARGV.fetch(2),
    "index" => ARGV.fetch(3)
  }.each do |name, path|
    archive = value.fetch("archives").fetch(name)
    abort "archive bytes" unless archive.fetch("bytes") == File.size(path)
    abort "archive sha" unless archive.fetch("sha256") ==
      Digest::SHA256.file(path).hexdigest
  end
' "$tmp/metrics.json" "$tmp/gzip.oci.tar" "$tmp/zstd.oci.tar" \
  "$tmp/index.oci.tar"

cp "$tmp/metrics.json" "$tmp/changed-baseline.json"
ruby -rjson -e '
  path = ARGV.fetch(0)
  value = JSON.parse(File.read(path))
  value.fetch("content")["index_digest"] = "sha256:" + ("f" * 64)
  File.write(path, "#{JSON.pretty_generate(value)}\n")
' "$tmp/changed-baseline.json"
set +e
"$metrics" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --index-archive "$tmp/index.oci.tar" \
  --output "$tmp/repro-failed.json" \
  --baseline "$tmp/changed-baseline.json" >"$tmp/repro.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "content reproducibility mismatch was accepted"
[ ! -e "$tmp/repro-failed.json" ] || fail "reproducibility failure emitted metrics"
grep -F 'normalized OCI content differs from baseline' "$tmp/repro.log" >/dev/null ||
  fail "reproducibility mismatch diagnostic changed"

ruby -rjson -e '
  source, output = ARGV
  value = JSON.parse(File.read(source))
  value.fetch("profiles").find { |profile| profile.fetch("id") == "3.4" }.
    fetch("size_budgets").fetch("linux/amd64").transform_values! { 1 }
  File.write(output, "#{JSON.pretty_generate(value)}\n")
' "$root/build/images.json" "$tmp/tiny-budget.json"
set +e
IMAGE_CATALOG="$tmp/tiny-budget.json" "$metrics" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --index-archive "$tmp/index.oci.tar" \
  --output "$tmp/budget-failed.json" >"$tmp/budget.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "size budget regression was accepted"
[ ! -e "$tmp/budget-failed.json" ] || fail "budget failure emitted metrics"
grep -F 'rootfs_bytes exceeds budget' "$tmp/budget.log" >/dev/null ||
  fail "budget diagnostic changed"

set +e
"$metrics" 3.4 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --index-archive "$tmp/index.oci.tar" \
  --output "$tmp" >"$tmp/write-error.log" 2>&1
status=$?
set -e
[ "$status" -eq 1 ] || fail "output write failure status changed"
grep -F 'image-metrics: ERROR' "$tmp/write-error.log" >/dev/null ||
  fail "output write failure was not reported cleanly"
if grep -F 'from ' "$tmp/write-error.log" >/dev/null; then
  fail "output write failure leaked a Ruby backtrace"
fi

printf '%s\n' 'image metrics and reproducibility: PASS'
