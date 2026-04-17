# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_filter '/vendor/'
  add_filter '/app/' # legacy Rails tree excluded from coverage math

  # Coverage floor is only meaningful when running the full suite (both unit
  # and integration specs). Partial runs (rspec --tag ~integration, or a
  # single file) will naturally show lower coverage. Rakefile sets
  # ENFORCE_COVERAGE=1 when running `rake spec`.
  minimum_coverage line: 80 if ENV['ENFORCE_COVERAGE'] == '1'
end

ENV['RACK_ENV'] ||= 'test'

require 'cgminer_manager'

Dir[File.join(__dir__, 'support', '**', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end
  config.order = :random
  Kernel.srand config.seed

  config.define_derived_metadata(file_path: %r{/spec/integration/}) do |meta|
    meta[:integration] = true
  end
end
