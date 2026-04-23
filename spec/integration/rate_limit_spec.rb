# frozen_string_literal: true

require 'rack/test'
require 'ipaddr'

RSpec.describe 'rate limiting', type: :integration do
  include Rack::Test::Methods

  def app = CgminerManager::HttpApp.new

  let(:miners_file) do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  # Monotonic-clock stub: lets us hold wall-clock "time" still inside an
  # example so multiple POSTs land in the same window without relying on
  # real sleeps.
  def freeze_clock(value = 1000.0)
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(value)
  end

  before { freeze_clock }

  describe 'threshold enforcement' do
    before do
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: miners_file,
        rate_limit_enabled: true, rate_limit_requests: 3, rate_limit_window_seconds: 60
      )
    end

    it 'returns 429 + Retry-After once the limit is exceeded in one window' do
      3.times do
        post '/manager/admin/version'
        expect(last_response.status).not_to eq(429)
      end

      post '/manager/admin/version'
      expect(last_response.status).to eq(429)
      expect(last_response.headers['Retry-After'].to_i).to be >= 1
    end

    it 'isolates buckets per client IP' do
      3.times { post '/manager/admin/version', {}, 'REMOTE_ADDR' => '1.1.1.1' }
      post '/manager/admin/version', {}, 'REMOTE_ADDR' => '1.1.1.1'
      expect(last_response.status).to eq(429)

      post '/manager/admin/version', {}, 'REMOTE_ADDR' => '2.2.2.2'
      expect(last_response.status).not_to eq(429)
    end
  end

  describe 'X-Forwarded-For trust' do
    before do
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: miners_file,
        rate_limit_enabled: true, rate_limit_requests: 2, rate_limit_window_seconds: 60,
        trusted_proxies: [IPAddr.new('127.0.0.0/8')]
      )
    end

    it 'consults X-Forwarded-For when REMOTE_ADDR is in trusted_proxies' do
      2.times do
        post '/manager/admin/version', {},
             'REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => '5.5.5.5'
      end
      post '/manager/admin/version', {},
           'REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => '5.5.5.5'
      expect(last_response.status).to eq(429)

      # Different client behind the same trusted proxy passes.
      post '/manager/admin/version', {},
           'REMOTE_ADDR' => '127.0.0.1', 'HTTP_X_FORWARDED_FOR' => '6.6.6.6'
      expect(last_response.status).not_to eq(429)
    end
  end

  describe 'disabled posture' do
    before do
      CgminerManager::HttpApp.configure_for_test!(
        monitor_url: 'http://localhost:9292', miners_file: miners_file,
        rate_limit_enabled: false
      )
    end

    it 'never 429s when rate_limit_enabled is false' do
      10.times { post '/manager/admin/version' }
      expect(last_response.status).not_to eq(429)
    end
  end
end
