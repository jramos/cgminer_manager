# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development, :test do
  gem 'brakeman', '>= 7.0'
  gem 'bundler-audit', '>= 0.9'
  # parallel 2.x requires Ruby >= 3.3; pin to 1.x so our Ruby 3.2 matrix entry
  # can still bundle. Transitive dep of rubocop / rubocop-ast.
  gem 'parallel', '< 2.0'
  gem 'rack-test', '>= 2.1'
  gem 'rake', '>= 13.2'
  gem 'rspec', '>= 3.13'
  gem 'rubocop', '>= 1.60'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec', '>= 2.27'
  gem 'simplecov', '>= 0.22'
  gem 'webmock', '>= 3.23'
end
