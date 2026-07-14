# frozen_string_literal: true

require "base64"
require "json"
require "pathname"
require "rubygems/version"
require "time"

module ImageCatalog
  PROFILE_ORDER = %w[3.4 4.0 4.1 4.2 5.0 trunk 5.1 6.0 6.1 7.0].freeze
  IMMUTABLE_PROFILE_IDS = %w[5.1 6.0 6.1 7.0].freeze
  MANAGED_TAG_COUNT = 14

  PINNED_IMAGE = /\A[a-z0-9][a-z0-9._\/-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?@sha256:[0-9a-f]{64}\z/.freeze
  MOVING_IMAGE = /\A[a-z0-9][a-z0-9._\/-]*:[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
  LOWER_SHA256 = /\A[0-9a-f]{64}\z/.freeze
  PACKAGE_TOKEN = /\A[a-z0-9][a-z0-9+_.@-]*\z/.freeze
  COMMAND_TOKEN = /\A[a-z][a-z0-9+_.-]*\z/.freeze
  GEM_TOKEN = /\A[a-z0-9][a-z0-9_-]*\z/.freeze
  GEM_REQUIREMENT = /\A(?:~>|=)?[0-9]+(?:\.[0-9]+)*\z/.freeze
  SAFE_PATH = /\A\/[A-Za-z0-9._\/-]+\z/.freeze
  VERSION_TOKEN = /\A[0-9]+\.[0-9]+\.[0-9]+\z/.freeze
  COMMIT_SHA = /\A[0-9a-f]{40}\z/.freeze
  MARIADB_CONNECTOR_SOURCE = %r{\Ahttps://codeload\.github\.com/mariadb-corporation/mariadb-connector-c/tar\.gz/[0-9a-f]{40}\z}.freeze
  RESOLUTION_KEYS = %w[
    builder_base created profile runtime_base source_commit
    source_date_epoch source_sha256 source_url
  ].sort.freeze

  class Error < StandardError; end
  class UsageError < Error; end

  class SchemaValidator
    def initialize(schema)
      @schema = schema
    end

    def validate!(value)
      validate_node!(value, @schema, "$")
    end

    private

    def validate_node!(value, schema, path)
      if schema.key?("$ref")
        validate_node!(value, resolve_ref(schema.fetch("$ref")), path)
        return
      end

      validate_type!(value, schema.fetch("type"), path) if schema.key?("type")

      if schema.key?("enum") && !schema.fetch("enum").include?(value)
        invalid!(path, "#{value.inspect} is not in enum")
      end
      if schema.key?("const") && value != schema.fetch("const")
        invalid!(path, "must equal #{schema.fetch('const').inspect}")
      end

      case value
      when Hash
        validate_object!(value, schema, path)
      when Array
        validate_array!(value, schema, path)
      when String
        validate_string!(value, schema, path)
      when Integer
        validate_integer!(value, schema, path)
      end
    end

    def resolve_ref(reference)
      unless reference.start_with?("#/")
        raise Error, "schema contains unsupported reference #{reference.inspect}"
      end

      reference.delete_prefix("#/").split("/").reduce(@schema) do |node, token|
        node.fetch(token.gsub("~1", "/").gsub("~0", "~"))
      end
    rescue KeyError
      raise Error, "schema contains unresolved reference #{reference.inspect}"
    end

    def validate_type!(value, expected, path)
      types = expected.is_a?(Array) ? expected : [expected]
      return if types.any? { |type| type_matches?(value, type) }

      invalid!(path, "must have type #{types.join(' or ')}")
    end

    def type_matches?(value, type)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else
        raise Error, "schema contains unsupported type #{type.inspect}"
      end
    end

    def validate_object!(value, schema, path)
      required = schema.fetch("required", [])
      missing = required - value.keys
      invalid!(path, "missing required key #{missing.first.inspect}") unless missing.empty?

      properties = schema.fetch("properties", {})
      if schema["additionalProperties"] == false
        unknown = value.keys - properties.keys
        invalid!(path, "unknown key #{unknown.first.inspect}") unless unknown.empty?
      end

      if schema.key?("minProperties") && value.length < schema.fetch("minProperties")
        invalid!(path, "must contain at least #{schema.fetch('minProperties')} properties")
      end

      value.each do |key, child|
        next unless properties.key?(key)

        validate_node!(child, properties.fetch(key), "#{path}.#{key}")
      end
    end

    def validate_array!(value, schema, path)
      if schema.key?("minItems") && value.length < schema.fetch("minItems")
        invalid!(path, "must contain at least #{schema.fetch('minItems')} items")
      end
      if schema.key?("maxItems") && value.length > schema.fetch("maxItems")
        invalid!(path, "must contain at most #{schema.fetch('maxItems')} items")
      end
      if schema["uniqueItems"] && value.uniq.length != value.length
        invalid!(path, "must contain unique items")
      end

      return unless schema.key?("items")

      value.each_with_index do |child, index|
        validate_node!(child, schema.fetch("items"), "#{path}[#{index}]")
      end
    end

    def validate_string!(value, schema, path)
      if schema.key?("minLength") && value.length < schema.fetch("minLength")
        invalid!(path, "must contain at least #{schema.fetch('minLength')} characters")
      end
      if schema.key?("maxLength") && value.length > schema.fetch("maxLength")
        invalid!(path, "must contain at most #{schema.fetch('maxLength')} characters")
      end
      if schema.key?("pattern") && !Regexp.new(schema.fetch("pattern")).match?(value)
        invalid!(path, "does not match pattern #{schema.fetch('pattern').inspect}")
      end
    end

    def validate_integer!(value, schema, path)
      if schema.key?("minimum") && value < schema.fetch("minimum")
        invalid!(path, "must be >= #{schema.fetch('minimum')}")
      end
      if schema.key?("maximum") && value > schema.fetch("maximum")
        invalid!(path, "must be <= #{schema.fetch('maximum')}")
      end
    end

    def invalid!(path, message)
      raise Error, "schema #{path}: #{message}"
    end
  end

  class Catalog
    attr_reader :data

    def self.load(catalog_path:, schema_path:)
      data = parse_json(catalog_path, "catalog")
      schema = parse_json(schema_path, "schema")
      SchemaValidator.new(schema).validate!(data)
      new(data).tap(&:validate!)
    end

    def self.load_resolution(path)
      parse_json(path, "resolution")
    end

    def self.parse_json(path, label)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise Error, "#{label} file not found: #{path}"
    rescue JSON::ParserError => error
      raise Error, "invalid #{label} JSON in #{path}: #{error.message}"
    end
    private_class_method :parse_json

    def initialize(data)
      @data = data
    end

    def validate!
      validate_no_control_characters!(data, "$")
      validate_tool_policy!
      validate_profiles!
      self
    end

    def profiles
      data.fetch("profiles")
    end

    def profile(id, resolution: nil)
      value = profiles.find { |candidate| candidate.fetch("id") == id }
      raise UsageError, "unknown profile #{id.inspect}" unless value

      return value unless resolution

      apply_resolution(value, resolution)
    end

    def managed_tags
      profiles.flat_map do |candidate|
        candidate.dig("tags", "moving") + candidate.dig("tags", "immutable")
      end
    end

    def matrix
      {"include" => profiles.map { |candidate| {"profile" => candidate.fetch("id")} }}
    end

    def compression
      data.dig("tool_policy", "compression")
    end

    def tool_policy
      data.fetch("tool_policy")
    end

    def build_args(id, resolution: nil)
      payload = Base64.strict_encode64(JSON.generate(profile(id, resolution: resolution)))
      ["--build-arg", "IMAGE_PROFILE_JSON_BASE64=#{payload}"]
    end

    private

    def apply_resolution(profile, resolution)
      id = profile.fetch("id")
      semantic_error!("resolution is only valid for trunk") unless id == "trunk"
      unless resolution.is_a?(Hash) && resolution.keys.sort == RESOLUTION_KEYS
        semantic_error!("trunk resolution has unknown or missing keys")
      end
      unless resolution.fetch("profile") == "trunk"
        semantic_error!("trunk resolution profile must equal trunk")
      end

      commit = resolution.fetch("source_commit")
      semantic_error!("trunk resolution commit must be a full lowercase SHA") unless COMMIT_SHA.match?(commit)
      expected_url = "https://codeload.github.com/redmine/redmine/tar.gz/#{commit}"
      unless resolution.fetch("source_url") == expected_url
        semantic_error!("trunk resolution URL contradicts commit")
      end
      unless LOWER_SHA256.match?(resolution.fetch("source_sha256"))
        semantic_error!("trunk resolution archive checksum must be a full lowercase sha256")
      end

      epoch = resolution.fetch("source_date_epoch")
      semantic_error!("trunk resolution epoch must be a positive integer") unless epoch.is_a?(Integer) && epoch.positive?
      begin
        created = Time.iso8601(resolution.fetch("created"))
      rescue ArgumentError, TypeError
        semantic_error!("trunk resolution created must be RFC3339")
      end
      unless created.utc.iso8601 == resolution.fetch("created") &&
             created.to_i == epoch
        semantic_error!("trunk resolution timestamp and epoch disagree")
      end

      builder_base = resolution.fetch("builder_base")
      runtime_base = resolution.fetch("runtime_base")
      validate_pinned_image!(builder_base, "trunk resolution builder_base")
      validate_pinned_image!(runtime_base, "trunk resolution runtime_base")
      expected_prefix = "#{profile.dig('base', 'reference')}@sha256:"
      expected_runtime = profile.dig("base", "runtime_reference")
      unless builder_base.start_with?(expected_prefix) &&
             runtime_base == expected_runtime
        semantic_error!("trunk resolution bases contradict the catalog")
      end

      resolved = JSON.parse(JSON.generate(profile))
      resolved["source"] = {
        "kind" => "resolved_git_archive",
        "url" => resolution.fetch("source_url"),
        "sha256" => resolution.fetch("source_sha256"),
        "commit" => commit,
        "source_date_epoch" => epoch
      }
      resolved["base"]["reference"] = builder_base
      resolved
    rescue KeyError => error
      semantic_error!("trunk resolution missing #{error.key.inspect}")
    end

    def validate_tool_policy!
      policy = data.fetch("tool_policy")
      %w[source_base toolchain registry_tool].each do |key|
        validate_pinned_image!(policy.fetch(key), "tool_policy.#{key}")
      end
      policy.fetch("test_images").each do |name, reference|
        validate_pinned_image!(reference, "tool_policy.test_images.#{name}")
      end

      compression = policy.fetch("compression")
      candidates = compression.fetch("zstd_candidates")
      semantic_error!("zstd_candidates must not be empty") if candidates.empty?
      unless candidates == candidates.sort && candidates.uniq == candidates
        semantic_error!("zstd_candidates must be sorted and unique")
      end
      if compression.key?("selected_zstd_level") &&
         !candidates.include?(compression.fetch("selected_zstd_level"))
        semantic_error!("selected_zstd_level must be one of zstd_candidates")
      end
    end

    def validate_profiles!
      ids = profiles.map { |candidate| candidate.fetch("id") }
      duplicate_id = duplicate(ids)
      semantic_error!("duplicate profile id #{duplicate_id.inspect}") if duplicate_id
      unless ids == PROFILE_ORDER
        semantic_error!("profile ids must be exactly #{PROFILE_ORDER.join(' ')} in catalog order")
      end

      all_tags = managed_tags
      duplicate_tag = duplicate(all_tags)
      semantic_error!("duplicate managed tag #{duplicate_tag.inspect}") if duplicate_tag

      profiles.each { |candidate| validate_profile!(candidate) }

      profiles.group_by { |candidate| candidate.fetch("bundler_version") }.
        each do |version, candidates|
          digests = candidates.map { |candidate| candidate.fetch("bundler_gem_sha256") }.uniq
          if digests.length != 1
            semantic_error!("Bundler #{version} must use one gem SHA-256 across profiles")
          end
        end

      unless all_tags.length == MANAGED_TAG_COUNT
        semantic_error!("managed tag count must be exactly #{MANAGED_TAG_COUNT}")
      end
    end

    def validate_profile!(profile)
      id = profile.fetch("id")
      version = profile.fetch("redmine_version")
      expected_version = id == "trunk" ? /\Atrunk\z/ : /\A#{Regexp.escape(id)}\.\d+\z/
      unless expected_version.match?(version)
        semantic_error!("#{id}: Redmine version #{version.inspect} contradicts profile id")
      end

      unless profile.fetch("platforms") == ["linux/amd64"]
        semantic_error!("#{id}: platforms must be exactly linux/amd64")
      end

      {
        "ruby.version" => profile.dig("ruby", "version"),
        "bundler_version" => profile.fetch("bundler_version"),
        "puma_version" => profile.fetch("puma_version")
      }.each do |field, value|
        semantic_error!("#{id}: unsafe #{field} #{value.inspect}") unless VERSION_TOKEN.match?(value)
      end
      unless LOWER_SHA256.match?(profile.fetch("bundler_gem_sha256"))
        semantic_error!("#{id}: Bundler gem requires a full lowercase sha256")
      end
      if !profile.fetch("force_ruby_platform") &&
         Gem::Version.new(profile.fetch("bundler_version")) < Gem::Version.new("2.5.6")
        semantic_error!("#{id}: native musl gems require Bundler >= 2.5.6")
      end

      validate_source_and_base!(profile)
      validate_mariadb_connector!(profile)
      validate_packages!(profile)
      validate_gems!(profile)
      validate_runtime_checks!(profile)
      validate_tags!(profile)
      validate_oci!(profile)
      validate_budgets!(profile) if profile.key?("size_budgets")
    end

    def validate_source_and_base!(profile)
      id = profile.fetch("id")
      source = profile.fetch("source")
      reference = profile.dig("base", "reference")

      if id == "trunk"
        unless source.fetch("kind") == "git_archive"
          semantic_error!("trunk must use source kind git_archive")
        end
        expected = {
          "kind" => "git_archive",
          "repository" => "https://github.com/redmine/redmine",
          "ref" => "refs/heads/master"
        }
        semantic_error!("trunk source must use the approved moving repository/ref") unless source == expected
        if reference.include?("@sha256:") || !MOVING_IMAGE.match?(reference)
          semantic_error!("trunk base must remain moving before resolution")
        end
        unless profile.dig("ruby", "install_mode") == "base_image"
          semantic_error!("trunk Ruby install mode must be base_image")
        end
        validate_base_image_ruby_version!(profile, reference)
        validate_runtime_base!(profile, reference)
        return
      end

      if source.fetch("kind") == "git_archive"
        semantic_error!("only trunk may use git_archive")
      end
      unless source.fetch("kind") == "release_archive"
        semantic_error!("#{id}: release must use source kind release_archive")
      end
      %w[url sha256 source_date_epoch].each do |key|
        semantic_error!("#{id}: release source requires #{key}") unless source.key?(key)
      end
      unless source.keys.sort == %w[kind sha256 source_date_epoch url]
        semantic_error!("#{id}: release source contains contradictory fields")
      end

      url = source.fetch("url")
      semantic_error!("#{id}: release source URL must be HTTPS") unless url.start_with?("https://")
      expected_url = "https://www.redmine.org/releases/redmine-#{profile.fetch('redmine_version')}.tar.gz"
      semantic_error!("#{id}: release source URL contradicts Redmine version") unless url == expected_url
      unless LOWER_SHA256.match?(source.fetch("sha256"))
        semantic_error!("#{id}: release source requires a full lowercase sha256")
      end
      unless source.fetch("source_date_epoch").positive?
        semantic_error!("#{id}: source_date_epoch must be positive")
      end
      unless PINNED_IMAGE.match?(reference)
        semantic_error!("#{id}: release base must use a full lowercase sha256 digest")
      end

      expected_mode = reference.start_with?("alpine:") ? "alpine_package" : "base_image"
      unless profile.dig("ruby", "install_mode") == expected_mode
        semantic_error!("#{id}: Ruby install mode contradicts base image")
      end
      validate_base_image_ruby_version!(profile, reference) if expected_mode == "base_image"
      validate_runtime_base!(profile, reference)
    end

    def validate_base_image_ruby_version!(profile, reference)
      image = reference.split("@", 2).first
      match = %r{(?:\A|/)ruby:([0-9]+\.[0-9]+)(?:[.-]|\z)}.match(image)
      version = profile.dig("ruby", "version")
      unless match && version.start_with?("#{match[1]}.")
        semantic_error!("#{profile.fetch('id')}: Ruby version contradicts base image")
      end
    end

    def validate_runtime_base!(profile, builder_reference)
      id = profile.fetch("id")
      mode = profile.dig("ruby", "install_mode")
      runtime_reference = profile.dig("base", "runtime_reference")

      if mode == "alpine_package"
        if runtime_reference && runtime_reference != builder_reference
          semantic_error!("#{id}: package Ruby runtime base must equal its builder base")
        end
        return
      end

      unless runtime_reference
        semantic_error!("#{id}: base-image Ruby requires a pinned plain Alpine runtime")
      end
      validate_pinned_image!(runtime_reference, "#{id}: runtime base")

      builder_image = builder_reference.split("@", 2).first
      runtime_image = runtime_reference.split("@", 2).first
      builder_alpine = /alpine([0-9]+\.[0-9]+)/.match(builder_image)
      runtime_alpine = %r{(?:\A|/)alpine:([0-9]+\.[0-9]+)\z}.match(runtime_image)
      unless builder_alpine && runtime_alpine &&
             builder_alpine[1] == runtime_alpine[1]
        semantic_error!("#{id}: runtime Alpine series contradicts builder base")
      end
    end

    def validate_packages!(profile)
      id = profile.fetch("id")
      profile.fetch("packages").each do |kind, packages|
        duplicate_package = duplicate(packages)
        if duplicate_package
          semantic_error!("#{id}: duplicate #{kind} package #{duplicate_package.inspect}")
        end
        packages.each do |package|
          unless PACKAGE_TOKEN.match?(package)
            semantic_error!("#{id}: unsafe #{kind} package token #{package.inspect}")
          end
        end
      end
    end

    def validate_mariadb_connector!(profile)
      connector = profile["mariadb_connector"]
      return unless connector

      id = profile.fetch("id")
      unless VERSION_TOKEN.match?(connector.fetch("version"))
        semantic_error!("#{id}: unsafe MariaDB Connector/C version")
      end
      unless MARIADB_CONNECTOR_SOURCE.match?(connector.fetch("source_url"))
        semantic_error!("#{id}: MariaDB Connector/C source must pin an immutable commit")
      end
      unless LOWER_SHA256.match?(connector.fetch("source_sha256"))
        semantic_error!("#{id}: MariaDB Connector/C source requires a full lowercase sha256")
      end

      packages = profile.fetch("packages")
      required_build = %w[build-base cmake openssl-dev zlib-dev]
      missing_build = required_build - packages.fetch("build")
      unless missing_build.empty?
        semantic_error!("#{id}: MariaDB Connector/C build package missing #{missing_build.first}")
      end
      if packages.fetch("build").include?("mariadb-dev") ||
         packages.fetch("runtime").any? { |package| package.start_with?("mariadb") }
        semantic_error!("#{id}: source-built MariaDB Connector/C must not mix system connector packages")
      end

      paths = profile.dig("runtime_checks", "paths")
      %w[
        /opt/mariadb-connector/lib/mariadb/libmariadb.so.3
        /opt/mariadb-connector/lib/mariadb/plugin
      ].each do |path|
        semantic_error!("#{id}: MariaDB Connector/C runtime path missing #{path}") unless paths.include?(path)
      end
    end

    def validate_gems!(profile)
      id = profile.fetch("id")
      gems = profile.fetch("compatibility_gems")
      names = gems.map { |gem| gem.fetch("name") }
      duplicate_name = duplicate(names)
      semantic_error!("#{id}: duplicate compatibility gem #{duplicate_name.inspect}") if duplicate_name
      semantic_error!("#{id}: Puma must use puma_version, not compatibility_gems") if names.include?("puma")
      names.each do |name|
        semantic_error!("#{id}: unsafe gem token #{name.inspect}") unless GEM_TOKEN.match?(name)
      end
      gems.each do |gem|
        requirement = gem.fetch("requirement")
        next if requirement.nil? || GEM_REQUIREMENT.match?(requirement)

        semantic_error!("#{id}: unsafe gem requirement #{requirement.inspect}")
      end
    end

    def validate_runtime_checks!(profile)
      id = profile.fetch("id")
      checks = profile.fetch("runtime_checks")
      %w[commands requires paths cleanup_keep_paths].each do |key|
        duplicate_value = duplicate(checks.fetch(key))
        semantic_error!("#{id}: duplicate runtime #{key} entry #{duplicate_value.inspect}") if duplicate_value
      end
      checks.fetch("commands").each do |command|
        semantic_error!("#{id}: unsafe command token #{command.inspect}") unless COMMAND_TOKEN.match?(command)
      end
      checks.fetch("requires").each do |gem|
        semantic_error!("#{id}: unsafe required gem token #{gem.inspect}") unless GEM_TOKEN.match?(gem)
      end
      (checks.fetch("paths") + checks.fetch("cleanup_keep_paths")).each do |path|
        unless SAFE_PATH.match?(path) && Pathname.new(path).cleanpath.to_s == path && !path.include?("//")
          semantic_error!("#{id}: unsafe runtime path #{path.inspect}")
        end
      end
    end

    def validate_tags!(profile)
      id = profile.fetch("id")
      version = profile.fetch("redmine_version")
      tags = profile.fetch("tags")
      unless tags.fetch("moving") == [id]
        semantic_error!("#{id}: moving tag contradicts profile id")
      end
      expected_immutable = IMMUTABLE_PROFILE_IDS.include?(id) ? [version] : []
      unless tags.fetch("immutable") == expected_immutable &&
             (expected_immutable.empty? || expected_immutable == [version])
        semantic_error!("#{id}: immutable tags contradict Redmine version")
      end
    end

    def validate_oci!(profile)
      id = profile.fetch("id")
      version = profile.fetch("redmine_version")
      oci = profile.fetch("oci")
      constants = {
        "authors" => "Alexey Ivanov <lexa.ivanov@gmail.com>",
        "source" => "https://github.com/inspired-geek/redmine-alpine",
        "url" => "https://github.com/inspired-geek/redmine-alpine",
        "documentation" => "https://github.com/inspired-geek/redmine-alpine#readme",
        "licenses" => "GPL-2.0-or-later"
      }
      constants.each do |key, expected|
        semantic_error!("#{id}: OCI #{key} must equal #{expected.inspect}") unless oci.fetch(key) == expected
      end
      expected_title = id == "trunk" ? "Redmine trunk Alpine" : "Redmine #{id} Alpine"
      semantic_error!("#{id}: OCI title contradicts profile") unless oci.fetch("title") == expected_title
      semantic_error!("#{id}: OCI version contradicts profile") unless oci.fetch("version") == version
      description = oci.fetch("description")
      unless description.include?("Puma") && description.include?("mandatory build")
        semantic_error!("#{id}: OCI description must state Puma and common mandatory-build policy")
      end
    end

    def validate_budgets!(profile)
      id = profile.fetch("id")
      budgets = profile.fetch("size_budgets")
      unless budgets.keys.sort == profile.fetch("platforms").sort
        semantic_error!("#{id}: size budget platforms must match profile platforms")
      end
    end

    def validate_pinned_image!(reference, field)
      return if PINNED_IMAGE.match?(reference)

      semantic_error!("#{field} must use a full lowercase sha256 digest")
    end

    def validate_no_control_characters!(value, path)
      case value
      when Hash
        value.each { |key, child| validate_no_control_characters!(child, "#{path}.#{key}") }
      when Array
        value.each_with_index do |child, index|
          validate_no_control_characters!(child, "#{path}[#{index}]")
        end
      when String
        semantic_error!("#{path}: control characters are forbidden") if value.match?(/[[:cntrl:]]/)
      end
    end

    def duplicate(values)
      seen = {}
      values.find do |value|
        duplicate_value = seen.key?(value)
        seen[value] = true
        duplicate_value
      end
    end

    def semantic_error!(message)
      raise Error, "semantic: #{message}"
    end
  end
end
