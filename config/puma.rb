environment ENV.fetch("RAILS_ENV", "production")

port_number = Integer(ENV.fetch("PORT", "8080"), 10)
thread_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "5"), 10)
worker_count = Integer(ENV.fetch("WEB_CONCURRENCY", "1"), 10)

raise ArgumentError, "PORT must be positive" unless port_number.positive?
raise ArgumentError, "RAILS_MAX_THREADS must be positive" unless thread_count.positive?
raise ArgumentError, "WEB_CONCURRENCY must be positive" unless worker_count.positive?

bind "tcp://0.0.0.0:#{port_number}"
threads thread_count, thread_count

if worker_count > 1
  workers worker_count
  preload_app!
end

pidfile "/usr/src/redmine/tmp/pids/puma.pid"
