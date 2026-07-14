#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  expected=$1
  actual=$2
  message=$3
  [ "$actual" = "$expected" ] ||
    fail "$message (expected: $expected; actual: $actual)"
}

[ -x scripts/image-catalog ] || fail "missing executable scripts/image-catalog"
[ -f scripts/lib/image_catalog.rb ] || fail "missing scripts/lib/image_catalog.rb"
[ -f build/images.json ] || fail "missing build/images.json"
[ -f build/images.schema.json ] || fail "missing build/images.schema.json"
[ -f build/compression-benchmark.json ] ||
  fail "missing build/compression-benchmark.json"

actual=$(scripts/image-catalog validate)
assert_equal 'catalog: PASS profiles=10 managed_tags=14' "$actual" \
  'validation summary changed'

actual=$(IMAGE_CATALOG=build/images.json scripts/image-catalog validate)
assert_equal 'catalog: PASS profiles=10 managed_tags=14' "$actual" \
  'IMAGE_CATALOG override changed validation'

ruby -rjson -rbase64 -ropen3 -rtmpdir <<'RUBY'
CATALOG_PATH = "build/images.json"
SCHEMA_PATH = "build/images.schema.json"
CLI = File.expand_path("scripts/image-catalog")
FIXTURE_GLOB = "tests/fixtures/catalog/*.json"

PROFILE_ORDER = %w[3.4 4.0 4.1 4.2 5.0 trunk 5.1 6.0 6.1 7.0].freeze
MANAGED_TAGS = %w[
  3.4 4.0 4.1 4.2 5.0 trunk 5.1 5.1.13 6.0 6.0.10 6.1 6.1.3 7.0 7.0.0
].freeze

VERSIONS = {
  "3.4" => "3.4.13",
  "4.0" => "4.0.9",
  "4.1" => "4.1.7",
  "4.2" => "4.2.11",
  "5.0" => "5.0.6",
  "trunk" => "trunk",
  "5.1" => "5.1.13",
  "6.0" => "6.0.10",
  "6.1" => "6.1.3",
  "7.0" => "7.0.0"
}.freeze

SOURCE_SHA256 = {
  "3.4" => "bcdf35c88509c7c47e3a50e72d38507c25bebf243aa7844c30ca3f8f1fe6baac",
  "4.0" => "04a772b0b8f8ce6493614a7cb22ed82cb9b43c75dcdbeb5c2f925bae98e0d5df",
  "4.1" => "bf56cade5d0a6623af590652bffe2865208f399fe77746d4e1bbd9d1a995a38a",
  "4.2" => "de4ce017c2ad0af94b2941259f356094f369b1b2c621b5a1dd8984a2cf10dc25",
  "5.0" => "488fe08f37a8eb1011415922a8ea743b7f38d8a7a5f8822950a34a375dcf08ee",
  "5.1" => "1a3d1039e474e787cebf223da148bf28373e4bca262197a53cfa6139640ebe5f",
  "6.0" => "0f3f3a7159188fbd65a365519037ebe6882c6dace78d8630de22c570ff20ca77",
  "6.1" => "61db3008c7fd18a3afc559ed656fd38fdf8df8220ac69598b319095183190b7a",
  "7.0" => "857e9f8860c31e4c531389e5d93eea26488dba69830484a3b0aa904be615e90a"
}.freeze

BASES = {
  "3.4" => "alpine:3.7@sha256:8421d9a84432575381bfabd248f1eb56f3aa21d9d7cd2511583c68c9b7511d10",
  "4.0" => "alpine:3.11@sha256:bcae378eacedab83da66079d9366c8f5df542d7ed9ab23bf487e3e1a8481375d",
  "4.1" => "alpine:3.11@sha256:bcae378eacedab83da66079d9366c8f5df542d7ed9ab23bf487e3e1a8481375d",
  "4.2" => "alpine:3.14@sha256:0f2d5c38dd7a4f4f733e688e3a6733cb5ab1ac6e3cb4603a5dd564e5bfb80eed",
  "5.0" => "alpine:3.17@sha256:8fc3dacfb6d69da8d44e42390de777e48577085db99aa4e4af35f483eb08b989",
  "trunk" => "ruby:3.4-alpine3.24",
  "5.1" => "ruby:3.2-alpine3.23@sha256:d206c25708a44df6a7ce22213ee5da9fc0a9f7b31ce884429ba758db48abdc62",
  "6.0" => "ruby:3.3-alpine3.24@sha256:940f1f8ba78c93b303eb2a632b249792cf60435517da260f3a1b9c8b8f1e7dfe",
  "6.1" => "ruby:3.4-alpine3.24@sha256:c5a5064d190055633011c03aa800170cc36945ff3afb5f6c915329f92d6f1e00",
  "7.0" => "ruby:3.4-alpine3.24@sha256:c5a5064d190055633011c03aa800170cc36945ff3afb5f6c915329f92d6f1e00"
}.freeze

RUBY_VERSIONS = {
  "3.4" => "2.4.10", "4.0" => "2.6.8", "4.1" => "2.6.8",
  "4.2" => "2.7.8", "5.0" => "3.1.5", "trunk" => "3.4.10",
  "5.1" => "3.2.11", "6.0" => "3.3.11", "6.1" => "3.4.10",
  "7.0" => "3.4.10"
}.freeze

SOURCE_EPOCHS = {
  "3.4" => 1_576_842_316,
  "4.0" => 1_619_448_008,
  "4.1" => 1_648_497_012,
  "4.2" => 1_696_056_002,
  "5.0" => 1_696_056_004,
  "5.1" => 1_781_551_502,
  "6.0" => 1_781_551_504,
  "6.1" => 1_781_551_506,
  "7.0" => 1_782_853_202
}.freeze

BUNDLER_VERSIONS = {
  "3.4" => "1.16.6",
  "4.0" => "2.4.20",
  "4.1" => "2.4.20",
  "4.2" => "2.4.22",
  "5.0" => "2.4.22",
  "trunk" => "2.6.9",
  "5.1" => "2.4.22",
  "6.0" => "2.5.23",
  "6.1" => "2.6.9",
  "7.0" => "2.6.9"
}.freeze

FORCE_RUBY_PLATFORM = {
  "3.4" => true,
  "4.0" => true,
  "4.1" => true,
  "4.2" => true,
  "5.0" => true,
  "trunk" => false,
  "5.1" => true,
  "6.0" => false,
  "6.1" => false,
  "7.0" => false
}.freeze

BUNDLER_GEM_SHA256 = {
  "1.16.6" => "07b445ea98d39032d257016a971a0c0947556eea7855ce64970da2a82e098605",
  "2.4.20" => "744b2b1951da613af2af6854f7c1f9e16dd90b4b66cd9af1a27a9f448c761bee",
  "2.4.22" => "747ba50b0e67df25cbd3b48f95831a77a4d53a581d55f063972fcb146d142c5f",
  "2.5.23" => "83d52433862a6076268d51d5c879e4467365db0bf376cd89aefb1661baf18618",
  "2.6.9" => "a25675ffbd055ae1186766cc1e120b4cf62588e88abb59b99c57e22b1c55c9eb"
}.freeze

FEATURE_IMAGEMAGICK6 = %w[
  ca-certificates ghostscript imagemagick6 shared-mime-info ttf-dejavu tzdata
].freeze
FEATURE_IMAGEMAGICK = %w[
  ca-certificates ghostscript imagemagick shared-mime-info ttf-dejavu tzdata
].freeze

PACKAGES = {
  "3.4" => {
    "feature" => FEATURE_IMAGEMAGICK6,
    "runtime" => %w[mariadb-client-libs ruby sqlite-libs],
    "build" => %w[
      build-base curl imagemagick6-dev libxslt-dev linux-headers mariadb-dev
      pax-utils ruby-dev sqlite-dev
    ]
  },
  "4.0" => {
    "feature" => FEATURE_IMAGEMAGICK6,
    "runtime" => %w[mariadb-connector-c ruby sqlite-libs],
    "build" => %w[
      build-base imagemagick6-dev linux-headers mariadb-dev pax-utils ruby-dev ruby-etc
      sqlite-dev
    ]
  },
  "4.1" => {
    "feature" => FEATURE_IMAGEMAGICK6,
    "runtime" => %w[mariadb-connector-c ruby sqlite-libs],
    "build" => %w[
      build-base imagemagick6-dev linux-headers mariadb-dev pax-utils ruby-dev ruby-etc
      sqlite-dev
    ]
  },
  "4.2" => {
    "feature" => FEATURE_IMAGEMAGICK6,
    "runtime" => %w[ruby sqlite-libs],
    "build" => %w[
      build-base cmake imagemagick6-dev linux-headers openssl-dev pax-utils ruby-dev
      ruby-etc sqlite-dev zlib-dev
    ]
  },
  "5.0" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c ruby sqlite-libs],
    "build" => %w[
      build-base imagemagick-dev linux-headers mariadb-dev pax-utils ruby-dev sqlite-dev
    ]
  },
  "5.1" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c sqlite-libs],
    "build" => %w[
      coreutils gcc make mariadb-dev musl-dev pax-utils patch sqlite-dev ttf2ufm
      wget yaml-dev zlib-dev
    ]
  },
  "6.0" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c sqlite-libs],
    "build" => %w[
      coreutils gcc make mariadb-dev musl-dev pax-utils patch sqlite-dev ttf2ufm
      wget yaml-dev zlib-dev
    ]
  },
  "6.1" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c sqlite-libs],
    "build" => %w[
      coreutils gcc make mariadb-dev musl-dev pax-utils patch sqlite-dev wget
      yaml-dev zlib-dev
    ]
  },
  "7.0" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c sqlite-libs],
    "build" => %w[
      coreutils gcc make mariadb-dev musl-dev pax-utils patch sqlite-dev wget
      yaml-dev zlib-dev
    ]
  },
  "trunk" => {
    "feature" => FEATURE_IMAGEMAGICK,
    "runtime" => %w[mariadb-connector-c sqlite-libs],
    "build" => %w[
      coreutils gcc make mariadb-dev musl-dev pax-utils patch sqlite-dev wget
      yaml-dev zlib-dev
    ]
  }
}.freeze

COMPATIBILITY_GEMS = {
  "3.4" => [
    ["builder", "=3.2.4"],
    ["sqlite3", "~>1.3.12"], ["mysql2", "~>0.4.6"], ["json", "~>2.6.3"],
    ["bigdecimal", "=1.3.5"], ["loofah", "=2.19.1"],
    ["tzinfo-data", nil], ["nio4r", "=2.7.0"]
  ],
  "4.0" => [
    ["builder", "=3.2.4"],
    ["sqlite3", "~>1.3.12"], ["mysql2", "~>0.5.0"], ["json", "~>2.6.3"],
    ["bigdecimal", "~>3.1.4"], ["loofah", "=2.19.1"], ["etc", "=1.4.2"],
    ["tzinfo-data", nil], ["nio4r", "=2.7.0"]
  ],
  "4.1" => [
    ["builder", "=3.2.4"],
    ["sqlite3", "~>1.4.0"], ["mysql2", "~>0.5.0"], ["json", "~>2.6.3"],
    ["bigdecimal", "~>3.1.4"], ["loofah", "=2.19.1"], ["etc", "=1.4.2"],
    ["tzinfo-data", nil], ["nio4r", "=2.7.0"]
  ],
  "4.2" => [
    ["builder", "=3.2.4"],
    ["sqlite3", "~>1.4.0"], ["mysql2", "~>0.5.0"], ["json", "~>2.6.3"],
    ["bigdecimal", "~>3.1.4"], ["etc", "~>1.4.2"],
    ["tzinfo-data", nil], ["nio4r", "=2.7.0"]
  ],
  "5.0" => [
    ["builder", "=3.2.4"],
    ["sqlite3", "~>1.4.0"], ["mysql2", "~>0.5.0"], ["tzinfo-data", nil]
  ],
  "5.1" => [
    ["sqlite3", "~>1.6.0"], ["mysql2", "~>0.5.0"],
    ["with_advisory_lock", nil]
  ],
  "6.0" => [
    ["sqlite3", "~>1.7.0"], ["mysql2", "~>0.5.0"],
    ["with_advisory_lock", nil]
  ],
  "6.1" => [
    ["sqlite3", "~>2.5.0"], ["mysql2", "~>0.5.0"],
    ["with_advisory_lock", nil]
  ],
  "7.0" => [
    ["sqlite3", "=2.9.4"], ["mysql2", "~>0.5.0"],
    ["with_advisory_lock", nil]
  ],
  "trunk" => [
    ["sqlite3", "=2.9.4"], ["mysql2", "~>0.5.0"],
    ["with_advisory_lock", nil]
  ]
}.freeze

FORCED_RUBY_PLATFORM_GEMS = {
  "6.0" => ["sqlite3"]
}.freeze

RUNTIME_PATHS = %w[
  /usr/src/redmine
  /usr/local/bundle
  /usr/local/bin/docker-entrypoint
  /usr/src/redmine/config/database.yml
  /usr/src/redmine/config/secrets.yml
  /usr/src/redmine/config/puma.rb
  /usr/src/redmine/files
  /usr/src/redmine/log
  /usr/src/redmine/plugins
  /usr/src/redmine/public/plugin_assets
  /usr/src/redmine/public/themes
  /usr/src/redmine/sqlite
  /usr/src/redmine/tmp
  /usr/src/redmine/tmp/pdf
  /usr/src/redmine/tmp/pids
].freeze

MARIADB_CONNECTOR_RUNTIME_PATHS = %w[
  /opt/mariadb-connector/lib/mariadb/libmariadb.so.3
  /opt/mariadb-connector/lib/mariadb/plugin
].freeze

MARIADB_CONNECTOR = {
  "version" => "3.3.18",
  "source_url" => "https://codeload.github.com/mariadb-corporation/mariadb-connector-c/tar.gz/9e2b0370de0076461ebae71a06acfb7a9364395b",
  "source_sha256" => "c9bb36de53cab97dbec2f3fc47219f9ddb8d7068e532c6abd9b18f8e5d3850fe"
}.freeze

REQUIRES = {
  "3.4" => %w[mysql2 sqlite3 puma nio4r json bigdecimal loofah blankslate],
  "4.0" => %w[mysql2 sqlite3 puma nio4r json bigdecimal loofah etc blankslate],
  "4.1" => %w[mysql2 sqlite3 puma nio4r json bigdecimal loofah etc blankslate],
  "4.2" => %w[mysql2 sqlite3 puma nio4r json bigdecimal etc blankslate],
  "5.0" => %w[mysql2 sqlite3 puma blankslate],
  "5.1" => %w[mysql2 sqlite3 puma with_advisory_lock],
  "6.0" => %w[mysql2 sqlite3 puma with_advisory_lock],
  "6.1" => %w[mysql2 sqlite3 puma commonmarker with_advisory_lock],
  "7.0" => %w[mysql2 sqlite3 puma commonmarker with_advisory_lock],
  "trunk" => %w[mysql2 sqlite3 puma commonmarker with_advisory_lock]
}.freeze

DESCRIPTIONS = {
  "3.4" => "Redmine 3.4.13 on Alpine with Puma; unsupported compatibility release in the common mandatory build",
  "4.0" => "Redmine 4.0.9 on Alpine with Puma; unsupported compatibility release in the common mandatory build",
  "4.1" => "Redmine 4.1.7 on Alpine with Puma; unsupported compatibility release in the common mandatory build",
  "4.2" => "Redmine 4.2.11 on Alpine with Puma; unsupported compatibility release in the common mandatory build",
  "5.0" => "Redmine 5.0.6 on Alpine with Puma; unsupported compatibility release in the common mandatory build",
  "trunk" => "Redmine trunk upstream development snapshot on Alpine with Puma; common mandatory build for upstream development",
  "5.1" => "Redmine 5.1.13 on Alpine with Puma; unsupported release retained in the common mandatory build",
  "6.0" => "Redmine 6.0.10 on Alpine with Puma; common mandatory build with important-security-fixes-only support",
  "6.1" => "Redmine 6.1.3 on Alpine with Puma; common mandatory build with bug-fix and security support",
  "7.0" => "Redmine 7.0.0 on Alpine with Puma; common mandatory build for the fully supported current stable release"
}.freeze

SIZE_BUDGETS = {
  "3.4" => {
    "linux/amd64" => {
      "rootfs_bytes" => 196_474_522,
      "gzip_bytes" => 68_766_391,
      "zstd_chunked_bytes" => 74_643_800
    }
  },
  "4.0" => {
    "linux/amd64" => {
      "rootfs_bytes" => 193_172_921,
      "gzip_bytes" => 69_063_571,
      "zstd_chunked_bytes" => 73_422_537
    }
  },
  "4.1" => {
    "linux/amd64" => {
      "rootfs_bytes" => 197_552_948,
      "gzip_bytes" => 72_893_252,
      "zstd_chunked_bytes" => 77_556_707
    }
  },
  "4.2" => {
    "linux/amd64" => {
      "rootfs_bytes" => 225_427_508,
      "gzip_bytes" => 84_266_561,
      "zstd_chunked_bytes" => 88_892_224
    }
  },
  "5.0" => {
    "linux/amd64" => {
      "rootfs_bytes" => 277_202_381,
      "gzip_bytes" => 97_174_266,
      "zstd_chunked_bytes" => 101_685_975
    }
  },
  "trunk" => {
    "linux/amd64" => {
      "rootfs_bytes" => 303_365_561,
      "gzip_bytes" => 122_387_378,
      "zstd_chunked_bytes" => 128_368_247
    }
  },
  "5.1" => {
    "linux/amd64" => {
      "rootfs_bytes" => 276_678_052,
      "gzip_bytes" => 114_564_088,
      "zstd_chunked_bytes" => 120_014_752
    }
  },
  "6.0" => {
    "linux/amd64" => {
      "rootfs_bytes" => 292_266_916,
      "gzip_bytes" => 117_888_831,
      "zstd_chunked_bytes" => 123_614_768
    }
  },
  "6.1" => {
    "linux/amd64" => {
      "rootfs_bytes" => 303_164_498,
      "gzip_bytes" => 121_625_971,
      "zstd_chunked_bytes" => 127_561_141
    }
  },
  "7.0" => {
    "linux/amd64" => {
      "rootfs_bytes" => 303_391_151,
      "gzip_bytes" => 122_385_774,
      "zstd_chunked_bytes" => 128_365_475
    }
  }
}.freeze

def assert(condition, message)
  raise message unless condition
end

def assert_equal(expected, actual, message)
  return if expected == actual

  raise "#{message}\nexpected: #{expected.inspect}\nactual:   #{actual.inspect}"
end

catalog = JSON.parse(File.read(CATALOG_PATH))
schema = JSON.parse(File.read(SCHEMA_PATH))

assert_equal(%w[profiles schema_version tool_policy], catalog.keys.sort, "top-level keys")
assert_equal(1, catalog.fetch("schema_version"), "schema version")
assert_equal(
  %w[compression registry_tool source_base test_images toolchain],
  catalog.fetch("tool_policy").keys.sort,
  "tool policy keys"
)
assert_equal(
  "alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b",
  catalog.dig("tool_policy", "source_base"),
  "source base"
)
assert_equal(
  "quay.io/podman/stable@sha256:766815d247ce0edfd8774770371d293728b0b500a219f35de98b408100f5d412",
  catalog.dig("tool_policy", "toolchain"),
  "toolchain image"
)
assert_equal(
  "quay.io/skopeo/stable:v1.22.2-immutable@sha256:4a16d57b37617a04b3d643079a477a2848efe892dffcdf0ce56df4262b65f810",
  catalog.dig("tool_policy", "registry_tool"),
  "registry tool image"
)
assert_equal(
  {
    "mariadb" => "mariadb:11.8.8@sha256:efb4959ef2c835cd735dbc388eb9ad6aab0c78dd64febcd51bc17481111890c4",
    "registry" => "registry:2@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
  },
  catalog.dig("tool_policy", "test_images"),
  "test images"
)
assert_equal(
  {
    "gzip_level" => 9,
    "zstd_candidates" => [3, 7, 10],
    "benchmark_runs" => 3,
    "selected_zstd_level" => 10
  },
  catalog.dig("tool_policy", "compression"),
  "compression policy"
)
assert_equal(
  %w[benchmark_runs gzip_level selected_zstd_level zstd_candidates],
  schema.dig("$defs", "compression", "required").sort,
  "required compression policy keys"
)

benchmark = JSON.parse(File.read("build/compression-benchmark.json"))
assert_equal(1, benchmark.fetch("schema_version"), "compression benchmark schema")
assert_equal(catalog.dig("tool_policy", "toolchain"),
             benchmark.dig("toolchain", "image"), "benchmark toolchain")
assert_equal(catalog.dig("tool_policy", "compression"), {
  "gzip_level" => benchmark.dig("policy", "gzip_level"),
  "zstd_candidates" => benchmark.dig("policy", "zstd_candidates"),
  "benchmark_runs" => benchmark.dig("policy", "runs"),
  "selected_zstd_level" => benchmark.dig("policy", "selected_zstd_level")
}, "benchmark policy projection")
benchmark.fetch("profiles").each do |id, measurement|
  levels = measurement.fetch("results").map { |result| result.fetch("level") }
  assert_equal([3, 7, 10], levels, "#{id}: benchmark candidate coverage")
  measurement.fetch("results").each do |result|
    assert_equal(3, result.fetch("seconds").length, "#{id}: benchmark run count")
  end
  selected = measurement.fetch("results").find { |result| result.fetch("level") == 10 }
  smallest = measurement.fetch("results").min_by { |result| result.fetch("layer_bytes") }
  assert_equal(smallest, selected, "#{id}: selected zstd level must be smallest")
end

profiles = catalog.fetch("profiles")
assert_equal(PROFILE_ORDER, profiles.map { |profile| profile.fetch("id") }, "profile order")
assert_equal(10, profiles.length, "profile count")

profile_keys = %w[
  base bundler_gem_sha256 bundler_version compatibility_gems force_ruby_platform
  id oci packages platforms puma_version redmine_version ruby runtime_checks
  source tags
].sort
oci_constants = {
  "authors" => "Alexey Ivanov <lexa.ivanov@gmail.com>",
  "source" => "https://github.com/inspired-geek/redmine-alpine",
  "url" => "https://github.com/inspired-geek/redmine-alpine",
  "documentation" => "https://github.com/inspired-geek/redmine-alpine#readme",
  "licenses" => "GPL-2.0-or-later"
}.freeze

profiles.each do |profile|
  id = profile.fetch("id")
  version = VERSIONS.fetch(id)

  expected_profile_keys = profile_keys.dup
  expected_profile_keys << "size_budgets"
  expected_profile_keys << "mariadb_connector" if id == "4.2"
  assert_equal(expected_profile_keys.sort, profile.keys.sort, "#{id}: closed profile keys")
  assert_equal(["linux/amd64"], profile.fetch("platforms"), "#{id}: platforms")
  assert_equal(version, profile.fetch("redmine_version"), "#{id}: Redmine version")
  assert_equal({"reference" => BASES.fetch(id)}, profile.fetch("base"), "#{id}: base")
  assert_equal(RUBY_VERSIONS.fetch(id), profile.dig("ruby", "version"), "#{id}: Ruby version")
  expected_mode = %w[3.4 4.0 4.1 4.2 5.0].include?(id) ? "alpine_package" : "base_image"
  assert_equal(expected_mode, profile.dig("ruby", "install_mode"), "#{id}: Ruby mode")
  assert_equal(BUNDLER_VERSIONS.fetch(id), profile.fetch("bundler_version"), "#{id}: Bundler")
  assert_equal(FORCE_RUBY_PLATFORM.fetch(id), profile.fetch("force_ruby_platform"),
               "#{id}: force Ruby platform")
  assert_equal(
    BUNDLER_GEM_SHA256.fetch(profile.fetch("bundler_version")),
    profile.fetch("bundler_gem_sha256"),
    "#{id}: Bundler gem SHA-256"
  )
  expected_puma = %w[3.4 4.0 4.1 4.2].include?(id) ? "6.6.1" : "8.0.2"
  assert_equal(expected_puma, profile.fetch("puma_version"), "#{id}: Puma")
  assert_equal(PACKAGES.fetch(id), profile.fetch("packages"), "#{id}: packages")
  expected_connector = id == "4.2" ? MARIADB_CONNECTOR : nil
  assert_equal(expected_connector, profile["mariadb_connector"],
               "#{id}: MariaDB Connector/C override")
  actual_gems = profile.fetch("compatibility_gems").map do |gem|
    [gem.fetch("name"), gem.fetch("requirement")]
  end
  assert_equal(COMPATIBILITY_GEMS.fetch(id), actual_gems, "#{id}: compatibility gems")
  forced_ruby_platform_gems = profile.fetch("compatibility_gems").each_with_object([]) do |gem, names|
    names << gem.fetch("name") if gem.fetch("force_ruby_platform", false)
  end
  assert_equal(FORCED_RUBY_PLATFORM_GEMS.fetch(id, []), forced_ruby_platform_gems,
               "#{id}: per-gem Ruby platform overrides")
  assert(!actual_gems.any? { |name, _requirement| name == "puma" },
         "#{id}: Puma must remain a separate field")

  checks = profile.fetch("runtime_checks")
  assert_equal(%w[ruby bundle gs convert], checks.fetch("commands"), "#{id}: commands")
  assert_equal(REQUIRES.fetch(id), checks.fetch("requires"), "#{id}: requires")
  expected_paths = RUNTIME_PATHS.dup
  expected_paths.concat(MARIADB_CONNECTOR_RUNTIME_PATHS) if id == "4.2"
  assert_equal(expected_paths, checks.fetch("paths"), "#{id}: paths")
  assert_equal([], checks.fetch("cleanup_keep_paths"), "#{id}: cleanup keep paths")

  expected_immutable = %w[5.1 6.0 6.1 7.0].include?(id) ? [version] : []
  assert_equal({"moving" => [id], "immutable" => expected_immutable},
               profile.fetch("tags"), "#{id}: tags")

  oci = profile.fetch("oci")
  oci_constants.each do |key, value|
    assert_equal(value, oci.fetch(key), "#{id}: OCI #{key}")
  end
  expected_title = id == "trunk" ? "Redmine trunk Alpine" : "Redmine #{id} Alpine"
  assert_equal(expected_title, oci.fetch("title"), "#{id}: OCI title")
  assert_equal(version, oci.fetch("version"), "#{id}: OCI version")
  assert_equal(DESCRIPTIONS.fetch(id), oci.fetch("description"), "#{id}: OCI description")
  assert_equal(SIZE_BUDGETS.fetch(id), profile.fetch("size_budgets"),
               "#{id}: measured size budgets")

  source = profile.fetch("source")
  if id == "trunk"
    assert_equal(
      {
        "kind" => "git_archive",
        "repository" => "https://github.com/redmine/redmine",
        "ref" => "refs/heads/master"
      },
      source,
      "trunk source"
    )
  else
    assert_equal(
      {
        "kind" => "release_archive",
        "url" => "https://www.redmine.org/releases/redmine-#{version}.tar.gz",
        "sha256" => SOURCE_SHA256.fetch(id),
        "source_date_epoch" => SOURCE_EPOCHS.fetch(id)
      },
      source,
      "#{id}: release source"
    )
  end
end

actual_tags = profiles.flat_map do |profile|
  profile.dig("tags", "moving") + profile.dig("tags", "immutable")
end
assert_equal(MANAGED_TAGS, actual_tags, "managed tags")
assert_equal(14, actual_tags.length, "managed tag count")

def run_cli(*arguments, env: {})
  stdout, stderr, status = Open3.capture3(env, CLI, *arguments)
  raise "#{arguments.inspect} failed: #{stderr}" unless status.success?
  raise "#{arguments.inspect} wrote stderr: #{stderr}" unless stderr.empty?

  stdout
end

matrix = JSON.parse(run_cli("matrix"))
assert_equal(
  {"include" => PROFILE_ORDER.map { |id| {"profile" => id} }},
  matrix,
  "matrix projection"
)
assert_equal(10, matrix.fetch("include").length, "matrix include count")
assert_equal("#{MANAGED_TAGS.join(' ')}\n", run_cli("tags"), "tags output")
assert_equal(
  catalog.dig("tool_policy", "compression"),
  JSON.parse(run_cli("compression")),
  "compression output"
)

PROFILE_ORDER.each do |id|
  expected_profile = profiles.find { |profile| profile.fetch("id") == id }
  assert_equal(expected_profile, JSON.parse(run_cli("profile", id)), "#{id}: profile output")

  argv = JSON.parse(run_cli("build-args", id))
  assert_equal(2, argv.length, "#{id}: build argv length")
  assert_equal("--build-arg", argv.fetch(0), "#{id}: typed build argv flag")
  prefix = "IMAGE_PROFILE_JSON_BASE64="
  assert(argv.fetch(1).start_with?(prefix), "#{id}: typed build argv assignment")
  payload = argv.fetch(1).delete_prefix(prefix)
  assert_equal(payload, Base64.strict_encode64(Base64.strict_decode64(payload)),
               "#{id}: strict Base64 payload")
  assert_equal(expected_profile, JSON.parse(Base64.strict_decode64(payload)),
               "#{id}: build argv profile payload")
  assert(!run_cli("build-args", id).match?(/\beval\b|`|\$\(|\n[^\]]*--build-arg/),
         "#{id}: executable shell fragment in build args")
end

def assert_closed_schema(node, path = "#")
  case node
  when Hash
    if node["type"] == "object"
      assert_equal(false, node["additionalProperties"], "#{path}: object schema must be closed")
    end
    node.each { |key, value| assert_closed_schema(value, "#{path}/#{key}") }
  when Array
    node.each_with_index { |value, index| assert_closed_schema(value, "#{path}/#{index}") }
  end
end

assert_closed_schema(schema)
assert(schema.dig("$defs", "profile", "required").include?("force_ruby_platform"),
       "profile schema must require force_ruby_platform")
assert(schema.dig("$defs", "profile", "required").include?("size_budgets"),
       "profile schema must require measured size budgets")
assert_equal(true,
             schema.dig("$defs", "compatibility_gem", "properties",
                        "force_ruby_platform", "const"),
             "per-gem force_ruby_platform must only allow true")

def pointer_tokens(pointer)
  raise "invalid JSON pointer #{pointer.inspect}" unless pointer.start_with?("/")

  pointer.split("/").drop(1).map { |token| token.gsub("~1", "/").gsub("~0", "~") }
end

def locate_parent(document, pointer)
  tokens = pointer_tokens(pointer)
  key = tokens.pop
  parent = tokens.reduce(document) do |value, token|
    value.is_a?(Array) ? value.fetch(Integer(token, 10)) : value.fetch(token)
  end
  [parent, key]
end

def read_pointer(document, pointer)
  pointer_tokens(pointer).reduce(document) do |value, token|
    value.is_a?(Array) ? value.fetch(Integer(token, 10)) : value.fetch(token)
  end
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def apply_operation(document, operation)
  parent, key = locate_parent(document, operation.fetch("path"))
  case operation.fetch("op")
  when "add"
    value = deep_copy(operation.fetch("value"))
    if parent.is_a?(Array)
      key == "-" ? parent << value : parent.insert(Integer(key, 10), value)
    else
      parent[key] = value
    end
  when "copy"
    value = deep_copy(read_pointer(document, operation.fetch("from")))
    if parent.is_a?(Array)
      key == "-" ? parent << value : parent.insert(Integer(key, 10), value)
    else
      parent[key] = value
    end
  when "remove"
    parent.is_a?(Array) ? parent.delete_at(Integer(key, 10)) : parent.delete(key)
  when "replace"
    value = deep_copy(operation.fetch("value"))
    parent.is_a?(Array) ? parent[Integer(key, 10)] = value : parent[key] = value
  else
    raise "unsupported fixture operation #{operation.fetch('op').inspect}"
  end
end

fixtures = Dir[FIXTURE_GLOB].sort
assert(fixtures.length >= 18, "focused invalid catalog fixtures are missing")

Dir.mktmpdir("image-catalog-test") do |directory|
  fixtures.each do |fixture_path|
    fixture = JSON.parse(File.read(fixture_path))
    mutated = deep_copy(catalog)
    fixture.fetch("operations").each { |operation| apply_operation(mutated, operation) }
    invalid_path = File.join(directory, File.basename(fixture_path))
    File.write(invalid_path, JSON.pretty_generate(mutated))

    stdout, stderr, status = Open3.capture3(
      {"IMAGE_CATALOG" => invalid_path}, CLI, "validate"
    )
    assert(!status.success?, "#{fixture_path}: invalid catalog was accepted")
    assert_equal("", stdout, "#{fixture_path}: invalid catalog wrote stdout")
    expected = fixture.fetch("expected")
    assert(stderr.include?(expected),
           "#{fixture_path}: expected diagnostic #{expected.inspect}, got #{stderr.inspect}")
  end
end

[
  ["profile", "missing"],
  ["build-args", "missing"],
  ["unknown-command"]
].each do |arguments|
  stdout, stderr, status = Open3.capture3(CLI, *arguments)
  assert(!status.success?, "#{arguments.inspect}: invalid invocation was accepted")
  assert_equal("", stdout, "#{arguments.inspect}: invalid invocation wrote stdout")
  assert(!stderr.empty?, "#{arguments.inspect}: invalid invocation had no diagnostic")
end
RUBY

ruby -c scripts/lib/image_catalog.rb | grep -F 'Syntax OK' >/dev/null
ruby -c scripts/image-catalog | grep -F 'Syntax OK' >/dev/null

printf 'Image catalog: PASS\n'
