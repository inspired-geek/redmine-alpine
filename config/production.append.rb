# This block is appended to Redmine's release-specific production.rb.
# Keep the upstream file intact so each release retains its own asset settings.
Rails.application.configure do
  if ENV["RAILS_LOG_TO_STDOUT"]
    logger = ActiveSupport::Logger.new(STDOUT)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end

  config.active_record.dump_schema_after_migration = false
end
