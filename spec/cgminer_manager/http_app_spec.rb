# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Unit coverage for HttpApp bits that aren't exercised end-to-end by the
# Rack::Test integration specs: the public class methods for parsing
# miners.yml and the fail-loud instance helper that guards against an
# unconfigured App.
RSpec.describe CgminerManager::HttpApp do
  describe '.parse_miners_file' do
    def with_miners_file(contents)
      Dir.mktmpdir('http_app_spec') do |dir|
        path = File.join(dir, 'miners.yml')
        File.write(path, contents)
        yield path
      end
    end

    it 'returns a frozen list of [host, port, label] tuples' do
      with_miners_file("- host: 10.0.0.5\n  port: 4029\n  label: rig-a\n") do |path|
        result = described_class.parse_miners_file(path)
        expect(result).to eq([['10.0.0.5', 4029, 'rig-a'].freeze])
        expect(result).to be_frozen
        expect(result.first).to be_frozen
      end
    end

    it 'defaults port to 4028 when absent' do
      with_miners_file("- host: 10.0.0.5\n") do |path|
        expect(described_class.parse_miners_file(path)).to eq([['10.0.0.5', 4028, nil].freeze])
      end
    end

    it 'tolerates a missing label by returning nil in the third slot' do
      with_miners_file("- host: 10.0.0.5\n  port: 4028\n") do |path|
        _host, _port, label = described_class.parse_miners_file(path).first
        expect(label).to be_nil
      end
    end

    it 'raises ConfigError when the YAML is a scalar, not a list' do
      with_miners_file('- just_a_string') do |path|
        expect { described_class.parse_miners_file(path) }
          .to raise_error(CgminerManager::ConfigError, /must be a YAML list/)
      end
    end

    it 'raises ConfigError when a miner entry is missing host' do
      with_miners_file("- port: 4028\n") do |path|
        expect { described_class.parse_miners_file(path) }
          .to raise_error(CgminerManager::ConfigError, /must be a YAML list/)
      end
    end

    it 'returns empty list for an empty YAML file' do
      with_miners_file('') do |path|
        expect(described_class.parse_miners_file(path)).to eq([])
      end
    end
  end

  describe '#configured_miners fail-loud guard' do
    # Pins the nil-default-plus-raise contract. If someone swapped the
    # `set :configured_miners, nil` default to `[]`, routes would
    # silently serve an empty miner list on a misconfigured deploy —
    # this spec would fail first.
    it 'raises CgminerManager::ConfigError when settings.configured_miners is nil' do
      described_class.set :configured_miners, nil
      app_instance = described_class.new!
      expect { app_instance.send(:configured_miners) }
        .to raise_error(CgminerManager::ConfigError, /HttpApp not configured/)
    end

    it 'returns settings.configured_miners when populated' do
      described_class.set :configured_miners, [%w[h 4028 label]]
      app_instance = described_class.new!
      expect(app_instance.send(:configured_miners)).to eq([%w[h 4028 label]])
    end
  end

  describe '.install_middleware!' do
    # Regression guard: the session-cookie middleware captures its
    # `secret:` at `use`-call time. If `use Rack::Session::Cookie` is
    # declared in a class-body `configure do … end` block, that capture
    # happens before Server#configure_http_app has populated
    # `settings.session_secret`, and the operator's configured secret
    # is silently discarded in favor of a fresh SecureRandom. This
    # spec pins the fix: the secret actually reaches the middleware
    # after install_middleware! runs.
    after do
      described_class.set :session_secret, nil
      described_class.set :production,     false
      described_class.install_middleware!
    end

    it 'captures settings.session_secret on the Rack::Session::Cookie middleware' do
      operator_secret = "operator-configured-secret-#{'x' * 40}"
      described_class.set :session_secret, operator_secret
      described_class.install_middleware!

      session_middleware = described_class.middleware.find { |m| m.first == Rack::Session::Cookie }
      expect(session_middleware).not_to be_nil
      expect(session_middleware[1].first[:secret]).to eq(operator_secret)
    end

    it 'captures settings.production on the secure flag' do
      described_class.set :production, true
      described_class.install_middleware!

      session_middleware = described_class.middleware.find { |m| m.first == Rack::Session::Cookie }
      expect(session_middleware[1].first[:secure]).to be(true)
    end

    it 'falls back to SecureRandom when session_secret is nil (dev/test)' do
      described_class.set :session_secret, nil
      described_class.install_middleware!

      session_middleware = described_class.middleware.find { |m| m.first == Rack::Session::Cookie }
      captured_secret = session_middleware[1].first[:secret]
      expect(captured_secret).to be_a(String)
      expect(captured_secret.length).to be >= 32
    end

    it 'does not accumulate duplicate middleware across repeated calls' do
      described_class.set :session_secret, 'a' * 64
      described_class.install_middleware!
      described_class.install_middleware!
      described_class.install_middleware!

      session_count = described_class.middleware.count { |m| m.first == Rack::Session::Cookie }
      admin_auth_count = described_class.middleware.count { |m| m.first == CgminerManager::AdminAuth }
      expect(session_count).to eq(1)
      expect(admin_auth_count).to eq(1)
    end

    # RateLimiter must sit above Session + AdminAuth so 401-probe
    # attacks are throttled before they consume auth resources. Any
    # future middleware reshuffle that drops the limiter below auth
    # regresses the 5.2 threat model; fail loudly.
    it 'installs RateLimiter above Rack::Session::Cookie and AdminAuth when enabled' do
      described_class.set :rate_limit_enabled, true
      described_class.set :rate_limit_requests, 60
      described_class.set :rate_limit_window_seconds, 60
      described_class.set :trusted_proxies, []
      described_class.install_middleware!

      classes = described_class.middleware.map(&:first)
      rate_index = classes.index(CgminerManager::RateLimiter)
      session_index = classes.index(Rack::Session::Cookie)
      auth_index = classes.index(CgminerManager::AdminAuth)

      expect(rate_index).not_to be_nil
      expect(rate_index).to be < session_index
      expect(rate_index).to be < auth_index
    end

    it 'omits RateLimiter from the stack when disabled' do
      described_class.set :rate_limit_enabled, false
      described_class.install_middleware!

      expect(described_class.middleware.map(&:first))
        .not_to include(CgminerManager::RateLimiter)
    end
  end
end
