# frozen_string_literal: true

bind "tcp://#{ENV.fetch('BIND', '127.0.0.1')}:#{ENV.fetch('PORT', '3000')}"
threads 1, 8
environment ENV.fetch('RACK_ENV', 'development')
