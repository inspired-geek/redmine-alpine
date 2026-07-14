#!/usr/bin/env ruby
# frozen_string_literal: true

require "erb"
require "yaml"

ROOT = File.expand_path("..", __dir__)
DATABASE_CONFIG = File.join(ROOT, "config/database.yml")
SECRETS_CONFIG = File.join(ROOT, "config/secrets.yml")
PUMA_CONFIG = File.join(ROOT, "config/puma.rb")
PRODUCTION_APPEND = File.join(ROOT, "config/production.append.rb")
ENVIRONMENT_KEYS = %w[
  DB_ADAPTER DB_NAME DB_HOST DB_PORT DB_USER DB_PASSWORD
  RAILS_MAX_THREADS SECRET_KEY_BASE REDMINE_SECRET_KEY_BASE
  RAILS_ENV RAILS_LOG_TO_STDOUT PORT WEB_CONCURRENCY
].freeze

def assert(condition, message)
  raise message unless condition
end

def with_environment(values)
  previous = ENVIRONMENT_KEYS.to_h { |key| [key, ENV[key]] }
  ENVIRONMENT_KEYS.each { |key| ENV.delete(key) }
  values.each { |key, value| ENV[key] = value }
  yield
ensure
  previous.each do |key, value|
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end

def render_yaml(path, environment = {})
  with_environment(environment) do
    rendered = ERB.new(File.read(path)).result
    YAML.safe_load(rendered, aliases: true)
  end
end

class PumaContract
  attr_reader :values

  def initialize(environment)
    @values = {}
    with_environment(environment) { instance_eval(File.read(PUMA_CONFIG), PUMA_CONFIG) }
  end

  def environment(value)
    values[:environment] = value
  end

  def bind(value)
    values[:bind] = value
  end

  def threads(minimum, maximum)
    values[:threads] = [minimum, maximum]
  end

  def workers(value)
    values[:workers] = value
  end

  def preload_app!
    values[:preload] = true
  end

  def before_fork(&block)
    values[:before_fork] = block
  end

  def on_worker_boot(&block)
    values[:on_worker_boot] = block
  end

  def pidfile(value)
    values[:pidfile] = value
  end
end

class ProductionConfigContract
  attr_accessor :logger
  attr_reader :active_record, :log_formatter

  def initialize
    @active_record = Struct.new(:dump_schema_after_migration).new
    @log_formatter = Object.new
  end

  def config
    self
  end
end

class ProductionApplicationContract
  attr_reader :config

  def initialize
    @config = ProductionConfigContract.new
  end

  def configure(&block)
    config.instance_eval(&block)
  end
end

module Rails
  class << self
    attr_accessor :application
  end
end

module ActiveSupport
  class Logger
    attr_accessor :formatter

    def initialize(_stream); end
  end

  class TaggedLogging
    def initialize(_logger); end
  end
end

def production_config(environment)
  with_environment(environment) do
    Rails.application = ProductionApplicationContract.new
    load PRODUCTION_APPEND
    Rails.application.config
  end
end

database = render_yaml(DATABASE_CONFIG)
sqlite = database.fetch("production")
assert(sqlite.fetch("adapter") == "sqlite3", "default adapter")
assert(sqlite.fetch("database") == "/usr/src/redmine/sqlite/redmine.db", "SQLite path")
assert(sqlite.fetch("pool") == 5, "default pool")
assert(sqlite.fetch("timeout") == 5000, "SQLite timeout")

database = render_yaml(
  DATABASE_CONFIG,
  "DB_ADAPTER" => "mysql2",
  "DB_NAME" => "issues",
  "DB_HOST" => "database",
  "DB_PORT" => "3307",
  "DB_USER" => "redmine_user",
  "DB_PASSWORD" => "secret",
  "RAILS_MAX_THREADS" => "7"
)
mysql = database.fetch("production")
assert(mysql.fetch("adapter") == "mysql2", "MariaDB adapter")
assert(mysql.fetch("database") == "issues", "MariaDB database")
assert(mysql.fetch("host") == "database", "MariaDB host")
assert(mysql.fetch("port") == 3307, "MariaDB port")
assert(mysql.fetch("username") == "redmine_user", "MariaDB user")
assert(mysql.fetch("password") == "secret", "MariaDB password")
assert(mysql.fetch("pool") == 7, "MariaDB pool")
assert(mysql.fetch("encoding") == "utf8mb4", "MariaDB encoding")
assert(
  mysql.dig("variables", "transaction_isolation") == "READ-COMMITTED",
  "MariaDB transaction isolation"
)

dangerous = 'part#{word\\path: "quoted"'
database = render_yaml(
  DATABASE_CONFIG,
  "DB_ADAPTER" => "mysql2",
  "DB_NAME" => dangerous,
  "DB_HOST" => dangerous,
  "DB_USER" => dangerous,
  "DB_PASSWORD" => dangerous
).fetch("production")
%w[database host username password].each do |key|
  assert(database.fetch(key) == dangerous, "YAML-safe #{key}")
end

begin
  render_yaml(DATABASE_CONFIG, "DB_ADAPTER" => "postgresql")
  raise "unsupported DB adapter was accepted"
rescue ArgumentError => error
  assert(error.message.include?("Unsupported DB_ADAPTER"), "unsupported adapter diagnostic")
end

begin
  render_yaml(DATABASE_CONFIG, "RAILS_MAX_THREADS" => "0")
  raise "zero pool was accepted"
rescue ArgumentError => error
  assert(error.message.include?("RAILS_MAX_THREADS must be positive"), "pool diagnostic")
end

begin
  render_yaml(DATABASE_CONFIG, "DB_ADAPTER" => "mysql2", "DB_PORT" => "0")
  raise "zero MariaDB port was accepted"
rescue ArgumentError => error
  assert(error.message.include?("DB_PORT must be positive"), "MariaDB port diagnostic")
end

secrets = render_yaml(SECRETS_CONFIG, "SECRET_KEY_BASE" => "preferred")
assert(secrets.dig("production", "secret_key_base") == "preferred", "preferred secret")
secrets = render_yaml(SECRETS_CONFIG, "REDMINE_SECRET_KEY_BASE" => "legacy")
assert(secrets.dig("production", "secret_key_base") == "legacy", "legacy secret")

begin
  render_yaml(SECRETS_CONFIG)
  raise "missing secret was accepted"
rescue KeyError
  # Expected.
end

puma = PumaContract.new({}).values
assert(puma.fetch(:environment) == "production", "Puma environment")
assert(puma.fetch(:bind) == "tcp://0.0.0.0:8080", "Puma bind")
assert(puma.fetch(:threads) == [5, 5], "Puma threads")
assert(!puma.key?(:workers), "Puma default workers")
assert(!puma.key?(:preload), "Puma default preload")
assert(!puma.key?(:before_fork), "Puma default before_fork")
assert(!puma.key?(:on_worker_boot), "Puma default on_worker_boot")
assert(puma.fetch(:pidfile) == "/usr/src/redmine/tmp/pids/puma.pid", "Puma pidfile")

puma = PumaContract.new(
  "PORT" => "9090",
  "RAILS_MAX_THREADS" => "7",
  "WEB_CONCURRENCY" => "3"
).values
assert(puma.fetch(:bind) == "tcp://0.0.0.0:9090", "custom Puma bind")
assert(puma.fetch(:threads) == [7, 7], "custom Puma threads")
assert(puma.fetch(:workers) == 3, "Puma workers")
assert(puma.fetch(:preload), "Puma preload")
assert(puma.fetch(:before_fork).respond_to?(:call), "Puma before_fork hook")
assert(puma.fetch(:on_worker_boot).respond_to?(:call), "Puma on_worker_boot hook")

module ActiveRecord
  class ConnectionPoolContract
    attr_reader :disconnects

    def initialize
      @disconnects = 0
    end

    def disconnect!
      @disconnects += 1
    end
  end

  class Base
    class << self
      attr_reader :establishments

      def connection_pool
        @connection_pool ||= ConnectionPoolContract.new
      end

      def establish_connection
        @establishments = (@establishments || 0) + 1
      end
    end
  end
end

puma.fetch(:before_fork).call
puma.fetch(:on_worker_boot).call
assert(ActiveRecord::Base.connection_pool.disconnects == 1, "Puma disconnect before fork")
assert(ActiveRecord::Base.establishments == 1, "Puma reconnect after fork")

production = production_config("RAILS_LOG_TO_STDOUT" => "")
assert(production.logger.nil?, "empty RAILS_LOG_TO_STDOUT disables stdout logging")
assert(!production.active_record.dump_schema_after_migration, "schema dump disabled")

production = production_config(
  "RAILS_LOG_TO_STDOUT" => "true",
  "REDMINE_SECRET_KEY_BASE" => "legacy-exec-secret"
)
assert(production.logger.is_a?(ActiveSupport::TaggedLogging), "stdout logging enabled")
assert(ENV["SECRET_KEY_BASE"].nil?, "production config leaked SECRET_KEY_BASE")

with_environment("REDMINE_SECRET_KEY_BASE" => "legacy-exec-secret") do
  Rails.application = ProductionApplicationContract.new
  load PRODUCTION_APPEND
  assert(ENV["SECRET_KEY_BASE"] == "legacy-exec-secret", "legacy secret alias")
end

%w[PORT RAILS_MAX_THREADS WEB_CONCURRENCY].each do |key|
  begin
    PumaContract.new(key => "0")
    raise "#{key}=0 was accepted"
  rescue ArgumentError => error
    assert(error.message.include?("must be positive"), "#{key} diagnostic")
  end
end

puts "runtime config contract: PASS"
