# frozen_string_literal: true

require_relative 'lib/cgminer_manager/version'

Gem::Specification.new do |spec|
  spec.name        = 'cgminer_manager'
  spec.version     = CgminerManager::VERSION
  spec.authors     = ['Justin Ramos']
  spec.email       = ['justin@southernmadelabs.com']
  spec.summary     = 'Web UI for managing cgminer-based mining rigs'
  spec.description = 'Sinatra service that displays data from cgminer_monitor and issues ' \
                     'pool-management commands to cgminer instances via cgminer_api_client.'
  spec.homepage    = 'https://github.com/jramos/cgminer_manager'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.files = Dir['lib/**/*', 'views/**/*', 'public/**/*', 'bin/*',
                   'config/**/*.example', 'config/puma.rb', 'config.ru',
                   'README.md', 'MIGRATION.md', 'CHANGELOG.md', 'LICENSE*'].reject { |f| File.directory?(f) }
  spec.bindir      = 'bin'
  spec.executables = ['cgminer_manager']

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.add_dependency 'cgminer_api_client', '~> 0.4'
  spec.add_dependency 'haml', '~> 6.3'
  spec.add_dependency 'http', '~> 5.2'
  spec.add_dependency 'puma', '~> 6.4'
  spec.add_dependency 'rack-protection', '~> 4.0'
  spec.add_dependency 'sinatra', '~> 4.0'
  spec.add_dependency 'sinatra-contrib', '~> 4.0' # content_for, namespace, etc.
end
