# frozen_string_literal: true

require 'rack/mock'
require 'ipaddr'

RSpec.describe CgminerManager::RateLimiter do
  let(:downstream) do
    ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['ok']] }
  end

  def env_for(path:, method: 'POST', remote_addr: '192.0.2.10', xff: nil)
    env = Rack::MockRequest.env_for(path, method: method)
    env['REMOTE_ADDR'] = remote_addr
    env['HTTP_X_FORWARDED_FOR'] = xff if xff
    env
  end

  # Replace Process.clock_gettime(CLOCK_MONOTONIC) with a controllable
  # counter so "wait past the window" can run in-process.
  def with_clock(start: 1000.0)
    clock = start
    stub_clock = ->(value) { allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(value) }
    stub_clock.call(clock)
    ticker = lambda do |n|
      clock += n
      stub_clock.call(clock)
    end
    yield ticker
  end

  describe 'path gating' do
    let(:middleware) { described_class.new(downstream, requests: 1, window_seconds: 60) }

    it 'passes through GET requests to admin paths (no bucket side effect)' do
      2.times do
        status, = middleware.call(env_for(path: '/manager/admin/version', method: 'GET'))
        expect(status).to eq(200)
      end
    end

    it 'passes through POSTs to non-rate-limited paths' do
      2.times do
        status, = middleware.call(env_for(path: '/something_else'))
        expect(status).to eq(200)
      end
    end

    it 'matches POST /manager/manage_pools' do
      with_clock do
        status1, = middleware.call(env_for(path: '/manager/manage_pools'))
        status2, = middleware.call(env_for(path: '/manager/manage_pools'))
        expect(status1).to eq(200)
        expect(status2).to eq(429)
      end
    end

    it 'matches POST /miner/:id/admin/:cmd' do
      with_clock do
        status1, = middleware.call(env_for(path: '/miner/rig-01/admin/version'))
        status2, = middleware.call(env_for(path: '/miner/rig-01/admin/version'))
        expect(status1).to eq(200)
        expect(status2).to eq(429)
      end
    end
  end

  describe 'threshold behavior' do
    let(:middleware) { described_class.new(downstream, requests: 3, window_seconds: 60) }

    it 'allows requests up to the limit and 429s after' do
      with_clock do
        3.times do
          status, = middleware.call(env_for(path: '/manager/admin/version'))
          expect(status).to eq(200)
        end
        status, headers, = middleware.call(env_for(path: '/manager/admin/version'))
        expect(status).to eq(429)
        expect(headers['Retry-After'].to_i).to be >= 1
        expect(headers['Content-Type']).to eq('text/plain')
      end
    end

    it 'keeps returning 429 for repeated rejected requests and does not inflate the stored counter' do
      with_clock do
        3.times { middleware.call(env_for(path: '/manager/admin/version')) }
        5.times do
          status, = middleware.call(env_for(path: '/manager/admin/version'))
          expect(status).to eq(429)
        end
        # The stored counter stays at the limit even though 5 more hits were rejected.
        buckets = middleware.instance_variable_get(:@buckets)
        expect(buckets.values.first[:count]).to eq(3)
      end
    end

    it 'resets the counter after the window elapses' do
      with_clock do |tick|
        3.times { middleware.call(env_for(path: '/manager/admin/version')) }
        status, = middleware.call(env_for(path: '/manager/admin/version'))
        expect(status).to eq(429)

        tick.call(61.0)

        status, = middleware.call(env_for(path: '/manager/admin/version'))
        expect(status).to eq(200)
      end
    end

    it 'isolates buckets per IP' do
      with_clock do
        3.times { middleware.call(env_for(path: '/manager/admin/version', remote_addr: '1.1.1.1')) }
        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: '1.1.1.1'))
        expect(status).to eq(429)

        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: '2.2.2.2'))
        expect(status).to eq(200)
      end
    end

    it 'logs rate_limit.exceeded on breach' do
      allow(CgminerManager::Logger).to receive(:warn)
      with_clock do
        3.times { middleware.call(env_for(path: '/manager/admin/version')) }
        middleware.call(env_for(path: '/manager/admin/version'))
      end
      expect(CgminerManager::Logger).to have_received(:warn).with(
        hash_including(
          event: 'rate_limit.exceeded',
          remote_ip: '192.0.2.10',
          path: '/manager/admin/version'
        )
      )
    end

    it 'floors Retry-After at 1 second even at the end of the window' do
      with_clock do |tick|
        3.times { middleware.call(env_for(path: '/manager/admin/version')) }
        tick.call(59.999) # ~1 ms left in the window
        _, headers, = middleware.call(env_for(path: '/manager/admin/version'))
        expect(headers['Retry-After'].to_i).to be >= 1
      end
    end
  end

  describe 'X-Forwarded-For trust' do
    let(:trusted) { [IPAddr.new('10.0.0.0/8')] }
    let(:middleware) do
      described_class.new(downstream, requests: 2, window_seconds: 60, trusted_proxies: trusted)
    end

    it 'ignores XFF when trusted_proxies is empty (default)' do
      mw = described_class.new(downstream, requests: 2, window_seconds: 60)
      with_clock do
        2.times { mw.call(env_for(path: '/manager/admin/version', remote_addr: '192.0.2.10', xff: '1.2.3.4')) }
        status, = mw.call(env_for(path: '/manager/admin/version', remote_addr: '192.0.2.10', xff: '9.9.9.9'))
        # Same REMOTE_ADDR, even with different XFF values -- XFF must be ignored.
        expect(status).to eq(429)
      end
    end

    it 'uses leftmost untrusted XFF hop when REMOTE_ADDR is a trusted proxy' do
      proxy = '10.0.0.5'
      with_clock do
        # Client 1.2.3.4 via trusted proxy 10.0.0.5 hits limit twice.
        2.times do
          middleware.call(env_for(path: '/manager/admin/version', remote_addr: proxy, xff: "1.2.3.4, #{proxy}"))
        end
        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: proxy, xff: "1.2.3.4, #{proxy}"))
        expect(status).to eq(429)

        # Different client 5.6.7.8 via the same proxy should not be throttled.
        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: proxy, xff: "5.6.7.8, #{proxy}"))
        expect(status).to eq(200)
      end
    end

    it 'ignores XFF when REMOTE_ADDR is not a trusted proxy' do
      with_clock do
        # REMOTE_ADDR=8.8.8.8 is not in 10/8, so XFF is attacker-forgeable.
        2.times { middleware.call(env_for(path: '/manager/admin/version', remote_addr: '8.8.8.8', xff: '1.2.3.4')) }
        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: '8.8.8.8', xff: '9.9.9.9'))
        expect(status).to eq(429)
      end
    end

    it 'falls back to REMOTE_ADDR when XFF contains an unparseable hop' do
      proxy = '10.0.0.5'
      with_clock do
        # Garbage XFF values must NOT become bucket keys (memory amplification defense).
        %w[not-an-ip-a not-an-ip-b not-an-ip-c].each_with_index do |garbage, i|
          status, = middleware.call(
            env_for(path: '/manager/admin/version', remote_addr: proxy, xff: "#{garbage}, #{proxy}")
          )
          expect(status).to eq(i < 2 ? 200 : 429)
        end

        # Only one bucket key was created, not three.
        buckets = middleware.instance_variable_get(:@buckets)
        expect(buckets.keys).to contain_exactly(proxy)
      end
    end

    it 'falls back to REMOTE_ADDR when every XFF hop is itself a trusted proxy' do
      with_clock do
        2.times { middleware.call(env_for(path: '/manager/admin/version', remote_addr: '10.0.0.5', xff: '10.0.0.1')) }
        status, = middleware.call(env_for(path: '/manager/admin/version', remote_addr: '10.0.0.5', xff: '10.0.0.2'))
        # Both XFF values are trusted, so both requests bucket to REMOTE_ADDR=10.0.0.5.
        expect(status).to eq(429)
      end
    end
  end
end
