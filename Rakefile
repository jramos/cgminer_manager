# frozen_string_literal: true

require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec) do |t|
  # Enforce the SimpleCov coverage floor only when rspec runs the full suite
  # via this rake task (not when CI or a developer runs a filtered subset).
  t.rspec_opts = nil
  ENV['ENFORCE_COVERAGE'] ||= '1'
end
RuboCop::RakeTask.new

task default: %i[rubocop spec]

desc 'Check Gemfile.lock against the ruby-advisory-db for known CVEs'
task :audit do
  sh 'bundle exec bundle-audit check --update'
end

namespace :spec do
  desc 'Capture /v2/* responses from $CGMINER_MONITOR_URL into spec/fixtures/monitor/'
  task :refresh_monitor_fixtures do
    require 'http'
    require 'fileutils'
    require 'cgi'

    base = ENV.fetch('CGMINER_MONITOR_URL') { abort 'Set CGMINER_MONITOR_URL' }
    miner = ENV.fetch('CGMINER_FIXTURE_MINER_ID', '127.0.0.1:4028')
    dir = File.expand_path('spec/fixtures/monitor', __dir__)
    FileUtils.mkdir_p(dir)

    fetch = lambda do |path, filename|
      resp = HTTP.timeout(5).get("#{base}#{path}")
      File.write(File.join(dir, filename), resp.body.to_s)
      puts "  wrote #{filename} (#{resp.status})"
    end

    fetch.call('/v2/miners', 'miners.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/summary", 'summary.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/devices", 'devices.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/pools",   'pools.json')
    fetch.call("/v2/miners/#{CGI.escape(miner)}/stats",   'stats.json')
    fetch.call("/v2/graph_data/hashrate?miner=#{CGI.escape(miner)}",
               'graph_data_hashrate.json')
    fetch.call('/v2/healthz', 'healthz.json')
  end
end
