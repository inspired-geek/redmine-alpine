#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
indexer=$root/scripts/oci-index
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_fixture() {
  format=$1
  output=$2
  mismatch=${3:-false}

  ruby -rjson -rdigest -rtime -rrubygems/package -e '
    format, output, catalog_path, mismatch = ARGV
    profile = JSON.parse(File.read(catalog_path)).fetch("profiles").find do |candidate|
      candidate.fetch("id") == "5.1"
    end
    abort "profile fixture missing" unless profile

    revision = mismatch == "true" ? "f" * 40 : "e" * 40
    created = Time.at(profile.dig("source", "source_date_epoch")).utc.iso8601
    labels = profile.fetch("oci").each_with_object({}) do |(key, value), result|
      result["org.opencontainers.image.#{key}"] = value
    end
    labels["org.opencontainers.image.created"] = created
    labels["org.opencontainers.image.revision"] = revision

    diff_id = "sha256:" + Digest::SHA256.hexdigest("uncompressed rootfs fixture")
    config = JSON.generate(
      "architecture" => "amd64",
      "os" => "linux",
      "config" => {"Labels" => labels},
      "rootfs" => {"type" => "layers", "diff_ids" => [diff_id]}
    )
    config_digest = Digest::SHA256.hexdigest(config)

    layer = "#{format} compressed layer fixture\n"
    layer_digest = Digest::SHA256.hexdigest(layer)
    layer_descriptor = {
      "mediaType" => if format == "gzip"
                       "application/vnd.oci.image.layer.v1.tar+gzip"
                     else
                       "application/vnd.oci.image.layer.v1.tar+zstd"
                     end,
      "digest" => "sha256:#{layer_digest}",
      "size" => layer.bytesize
    }
    if format == "zstd-chunked"
      layer_descriptor["annotations"] = {
        "io.github.containers.zstd-chunked.manifest-checksum" =>
          "sha256:" + ("a" * 64),
        "io.github.containers.zstd-chunked.manifest-position" => "1:2:3:1",
        "io.github.containers.zstd-chunked.tarsplit-position" => "4:5:6"
      }
    end

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
        "annotations" => {"org.opencontainers.image.ref.name" => "5.1"}
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
  ' "$format" "$output" "$root/build/images.json" "$mismatch"
}

make_fixture gzip "$tmp/gzip.oci.tar"
make_fixture zstd-chunked "$tmp/zstd.oci.tar"

[ -x "$indexer" ] || fail "missing executable scripts/oci-index"

"$indexer" 5.1 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --output "$tmp/dual.oci.tar"
"$indexer" 5.1 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/zstd.oci.tar" \
  --output "$tmp/dual-again.oci.tar" >/dev/null

[ -s "$tmp/dual.oci.tar" ] || fail "dual-compression archive missing"
cmp "$tmp/dual.oci.tar" "$tmp/dual-again.oci.tar" >/dev/null ||
  fail "OCI index archive is not deterministic"

ruby -rjson -rdigest -rrubygems/package -e '
  archive = ARGV.fetch(0)
  files = {}
  File.open(archive, "rb") do |file|
    Gem::Package::TarReader.new(file) do |tar|
      tar.each { |entry| files[entry.full_name] = entry.read if entry.file? }
    end
  end
  fetch_blob = lambda do |descriptor|
    digest = descriptor.fetch("digest")
    abort "non-sha256 descriptor" unless digest.start_with?("sha256:")
    value = files.fetch("blobs/sha256/#{digest.delete_prefix("sha256:")}")
    abort "descriptor size" unless value.bytesize == descriptor.fetch("size")
    abort "descriptor digest" unless Digest::SHA256.hexdigest(value) == digest.delete_prefix("sha256:")
    value
  end

  layout = JSON.parse(files.fetch("oci-layout"))
  abort "layout version" unless layout == {"imageLayoutVersion" => "1.0.0"}
  root = JSON.parse(files.fetch("index.json"))
  abort "root descriptor count" unless root.fetch("manifests").length == 1
  root_descriptor = root.fetch("manifests").first
  abort "root media type" unless root_descriptor.fetch("mediaType") ==
    "application/vnd.oci.image.index.v1+json"
  abort "root ref" unless root_descriptor.dig("annotations", "org.opencontainers.image.ref.name") == "5.1"

  index = JSON.parse(fetch_blob.call(root_descriptor))
  abort "index media type" unless index.fetch("mediaType") ==
    "application/vnd.oci.image.index.v1+json"
  descriptors = index.fetch("manifests")
  abort "variant count" unless descriptors.length == 2
  descriptors.each do |descriptor|
    abort "platform" unless descriptor.fetch("platform") ==
      {"architecture" => "amd64", "os" => "linux"}
  end
  gzip, zstd = descriptors
  abort "gzip must be first" if gzip.dig("annotations", "io.github.containers.compression.zstd")
  abort "zstd marker" unless zstd.dig("annotations", "io.github.containers.compression.zstd") == "true"

  gzip_manifest = JSON.parse(fetch_blob.call(gzip))
  zstd_manifest = JSON.parse(fetch_blob.call(zstd))
  abort "config mismatch" unless gzip_manifest.fetch("config") == zstd_manifest.fetch("config")
  abort "gzip layer" unless gzip_manifest.fetch("layers").all? do |layer|
    layer.fetch("mediaType") == "application/vnd.oci.image.layer.v1.tar+gzip"
  end
  abort "zstd layer" unless zstd_manifest.fetch("layers").all? do |layer|
    layer.fetch("mediaType") == "application/vnd.oci.image.layer.v1.tar+zstd" &&
      layer.fetch("annotations").keys.sort == %w[
        io.github.containers.zstd-chunked.manifest-checksum
        io.github.containers.zstd-chunked.manifest-position
        io.github.containers.zstd-chunked.tarsplit-position
      ]
  end

  annotations = index.fetch("annotations")
  %w[authors created description documentation licenses revision source title url version].each do |key|
    abort "missing index annotation #{key}" unless annotations.key?("org.opencontainers.image.#{key}")
  end
' "$tmp/dual.oci.tar"

make_fixture zstd-chunked "$tmp/mismatched-zstd.oci.tar" true
set +e
"$indexer" 5.1 \
  --gzip-archive "$tmp/gzip.oci.tar" \
  --zstd-chunked-archive "$tmp/mismatched-zstd.oci.tar" \
  --output "$tmp/rejected.oci.tar" >"$tmp/rejected.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "mismatched image configs were accepted"
[ ! -e "$tmp/rejected.oci.tar" ] || fail "rejected inputs emitted an archive"
grep -F 'gzip and zstd:chunked config descriptors differ' "$tmp/rejected.log" >/dev/null ||
  fail "mismatch diagnostic changed"

printf '%s\n' 'dual-compression OCI index: PASS'
