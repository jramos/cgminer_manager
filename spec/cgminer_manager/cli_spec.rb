# frozen_string_literal: true

RSpec.describe CgminerManager::CLI do
  def capture_run(argv)
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = stdout
    $stderr = stderr
    code = described_class.run(argv)
    [code, stdout.string, stderr.string]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  describe '.run' do
    context 'with unknown verb' do
      it 'prints usage and returns 64' do
        code, _stdout, stderr = capture_run(['banana'])
        expect(code).to eq(64)
        expect(stderr).to include('unknown verb: "banana"')
        expect(stderr).to include('usage: cgminer_manager {run|doctor|reload|version}')
      end
    end

    context 'with nil verb' do
      it 'prints usage and returns 64' do
        code, _stdout, stderr = capture_run([])
        expect(code).to eq(64)
        expect(stderr).to include('unknown verb: nil')
      end
    end

    context 'with version verb' do
      it 'prints VERSION and returns 0' do
        code, stdout, _stderr = capture_run(['version'])
        expect(code).to eq(0)
        expect(stdout).to eq("#{CgminerManager::VERSION}\n")
      end
    end

    context 'when Config.from_env raises ConfigError' do
      it 'prints the error and returns 2' do
        allow(CgminerManager::Config).to receive(:from_env)
          .and_raise(CgminerManager::ConfigError, 'missing thing')
        code, _stdout, stderr = capture_run(['run'])
        expect(code).to eq(2)
        expect(stderr).to include('config error: missing thing')
      end

      # End-to-end cover for the 1.3.0 admin-auth boot check. Uses the
      # real from_env path so a regression that moves validate_admin_auth!
      # (e.g., below record construction, or inside a rescue) still trips.
      it 'surfaces the admin-auth remediation message with exit 2' do
        miners_file = File.join(Dir.mktmpdir, 'miners.yml')
        File.write(miners_file, "- host: 127.0.0.1\n  port: 4028\n")
        keys = %w[
          CGMINER_MONITOR_URL MINERS_FILE SESSION_SECRET
          CGMINER_MANAGER_ADMIN_USER CGMINER_MANAGER_ADMIN_PASSWORD
          CGMINER_MANAGER_ADMIN_AUTH
        ]
        saved = ENV.to_h.slice(*keys)
        ENV['CGMINER_MONITOR_URL'] = 'http://localhost:9292'
        ENV['MINERS_FILE'] = miners_file
        ENV['SESSION_SECRET'] = 'x' * 64
        %w[CGMINER_MANAGER_ADMIN_USER CGMINER_MANAGER_ADMIN_PASSWORD
           CGMINER_MANAGER_ADMIN_AUTH].each { |k| ENV.delete(k) }

        code, _stdout, stderr = capture_run(['run'])
        expect(code).to eq(2)
        expect(stderr).to include('admin auth is required')
        expect(stderr).to include('MIGRATION.md')
      ensure
        keys.each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
      end
    end

    context 'with run verb' do
      let(:config) do
        instance_double(CgminerManager::Config, log_format: 'text', log_level: 'warn')
      end
      let(:server) { instance_double(CgminerManager::Server) }

      before do
        allow(CgminerManager::Config).to receive(:from_env).and_return(config)
        allow(CgminerManager::Server).to receive(:new).with(config).and_return(server)
        allow(CgminerManager::Logger).to receive(:format=)
        allow(CgminerManager::Logger).to receive(:level=)
        allow(server).to receive(:run)
      end

      it 'configures the logger format and level before starting the server' do
        described_class.run(['run'])
        expect(CgminerManager::Logger).to have_received(:format=).with('text').ordered
        expect(CgminerManager::Logger).to have_received(:level=).with('warn').ordered
        expect(server).to have_received(:run)
      end
    end

    context 'with doctor verb' do
      let(:config) do
        instance_double(CgminerManager::Config,
                        monitor_url: 'http://monitor:9292',
                        monitor_timeout: 2000,
                        rate_limit_enabled: true,
                        rate_limit_requests: 60,
                        rate_limit_window_seconds: 60,
                        trusted_proxies: [])
      end
      let(:miner) { instance_double(CgminerApiClient::Miner) }
      let(:client) { instance_double(CgminerManager::MonitorClient) }

      before do
        allow(CgminerManager::Config).to receive(:from_env).and_return(config)
        allow(config).to receive(:load_miners).and_return([['127.0.0.1', 4028]])
        allow(CgminerApiClient::Miner).to receive(:new).with('127.0.0.1', 4028).and_return(miner)
        allow(CgminerManager::MonitorClient).to receive(:new).and_return(client)
      end

      context 'when all checks pass' do
        it 'prints success and returns 0' do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(true)

          code, stdout, _stderr = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('doctor: all checks passed')
        end
      end

      context 'when reporting admin-auth posture' do
        around do |example|
          originals = ENV.to_h.slice(
            'CGMINER_MANAGER_ADMIN_USER',
            'CGMINER_MANAGER_ADMIN_PASSWORD',
            'CGMINER_MANAGER_ADMIN_AUTH'
          )
          example.run
        ensure
          %w[CGMINER_MANAGER_ADMIN_USER CGMINER_MANAGER_ADMIN_PASSWORD CGMINER_MANAGER_ADMIN_AUTH].each do |k|
            originals.key?(k) ? ENV[k] = originals[k] : ENV.delete(k)
          end
        end

        before do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(true)
        end

        it 'reports "required (credentials configured)" when creds are set' do
          ENV['CGMINER_MANAGER_ADMIN_USER'] = 'operator'
          ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret'
          ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
          code, stdout, _stderr = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('admin auth: required (credentials configured)')
        end

        it 'reports required even when a stale CGMINER_MANAGER_ADMIN_AUTH=off is present' do
          # Mirrors AdminAuth#call precedence: creds-set wins over =off.
          # A stale hatch must never lie about posture.
          ENV['CGMINER_MANAGER_ADMIN_USER'] = 'operator'
          ENV['CGMINER_MANAGER_ADMIN_PASSWORD'] = 's3cret'
          ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
          code, stdout, _stderr = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('admin auth: required (credentials configured)')
          expect(stdout).not_to include('DISABLED')
        end

        it 'reports DISABLED when the hatch is set and no creds are present' do
          ENV.delete('CGMINER_MANAGER_ADMIN_USER')
          ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
          ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
          code, stdout, _stderr = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('admin auth: DISABLED (CGMINER_MANAGER_ADMIN_AUTH=off)')
        end

        it 'fails with a misconfigured flag when neither creds nor hatch are set' do
          # Unreachable from production boot (Config.from_env raises first),
          # but doctor may be invoked in broken states; flag rather than lie.
          ENV.delete('CGMINER_MANAGER_ADMIN_USER')
          ENV.delete('CGMINER_MANAGER_ADMIN_PASSWORD')
          ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
          code, _stdout, stderr = capture_run(['doctor'])
          expect(code).to eq(1)
          expect(stderr).to include('FAIL: admin auth misconfigured')
        end
      end

      describe 'rate-limit posture' do
        before do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(true)
        end

        def rate_limit_config(**overrides)
          instance_double(
            CgminerManager::Config,
            monitor_url: 'http://monitor:9292', monitor_timeout: 2000,
            rate_limit_enabled: true, rate_limit_requests: 60, rate_limit_window_seconds: 60,
            trusted_proxies: [], **overrides
          ).tap do |c|
            allow(c).to receive(:load_miners).and_return([['127.0.0.1', 4028]])
            allow(CgminerManager::Config).to receive(:from_env).and_return(c)
          end
        end

        it 'reports "enabled" with configured values' do
          rate_limit_config(rate_limit_requests: 120, rate_limit_window_seconds: 30)
          code, stdout, = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('rate-limit: enabled (120 req / 30s per IP)')
        end

        it 'reports "DISABLED" when rate_limit_enabled is false' do
          rate_limit_config(rate_limit_enabled: false)
          code, stdout, = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('rate-limit: DISABLED (CGMINER_MANAGER_RATE_LIMIT=off)')
        end

        it 'reports "none" for trusted-proxies when empty' do
          rate_limit_config(trusted_proxies: [])
          code, stdout, = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('trusted-proxies: none (X-Forwarded-For ignored)')
        end

        it 'reports parsed CIDR list for trusted-proxies when set' do
          rate_limit_config(trusted_proxies: [IPAddr.new('127.0.0.1/32'), IPAddr.new('10.0.0.0/8')])
          code, stdout, = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to match(%r{trusted-proxies: 127\.0\.0\.1/32, 10\.0\.0\.0/8})
        end
      end

      context 'when monitor is unreachable' do
        it 'reports the failure and returns 1' do
          allow(client).to receive(:miners)
            .and_raise(CgminerManager::MonitorError::ConnectionError, 'boom')
          allow(miner).to receive(:available?).and_return(true)

          code, _stdout, stderr = capture_run(['doctor'])
          expect(code).to eq(1)
          expect(stderr).to include('FAIL: monitor unreachable: boom')
        end
      end

      context 'when cgminer is unreachable' do
        it 'reports the failure and returns 1' do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(false)

          code, _stdout, stderr = capture_run(['doctor'])
          expect(code).to eq(1)
          expect(stderr).to include('FAIL: cgminer 127.0.0.1:4028 unreachable')
        end
      end

      context 'when miners.yml has a miner not in monitor' do
        it 'reports the mismatch and returns 1' do
          allow(client).to receive(:miners).and_return(miners: [])
          allow(miner).to receive(:available?).and_return(true)

          code, _stdout, stderr = capture_run(['doctor'])
          expect(code).to eq(1)
          expect(stderr).to include('FAIL: miner 127.0.0.1:4028 in miners.yml but not in monitor')
        end
      end

      context 'when reporting pid-file posture' do
        around do |example|
          saved = ENV.to_h.slice('CGMINER_MANAGER_PID_FILE')
          example.run
        ensure
          if saved.key?('CGMINER_MANAGER_PID_FILE')
            ENV['CGMINER_MANAGER_PID_FILE'] =
              saved['CGMINER_MANAGER_PID_FILE']
          else
            ENV.delete('CGMINER_MANAGER_PID_FILE')
          end
        end

        before do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(true)
        end

        it 'reports "not configured" when CGMINER_MANAGER_PID_FILE is unset' do
          ENV.delete('CGMINER_MANAGER_PID_FILE')
          code, stdout, _stderr = capture_run(['doctor'])
          expect(code).to eq(0)
          expect(stdout).to include('pid file: not configured')
        end

        it 'reports OK when the pid file exists and the pid is alive' do
          Dir.mktmpdir do |dir|
            pid_path = File.join(dir, 'cm.pid')
            File.write(pid_path, "#{Process.pid}\n")
            ENV['CGMINER_MANAGER_PID_FILE'] = pid_path

            code, stdout, _stderr = capture_run(['doctor'])
            expect(code).to eq(0)
            expect(stdout).to include("pid file: OK (pid #{Process.pid})")
          end
        end

        it 'reports STALE when the pid is not running' do
          Dir.mktmpdir do |dir|
            pid_path = File.join(dir, 'cm.pid')
            File.write(pid_path, "9999999\n")
            ENV['CGMINER_MANAGER_PID_FILE'] = pid_path
            allow(Process).to receive(:kill).with(0, 9_999_999).and_raise(Errno::ESRCH)

            code, _stdout, stderr = capture_run(['doctor'])
            expect(code).to eq(1)
            expect(stderr).to include('pid file: STALE')
          end
        end

        it 'reports missing when configured but absent' do
          ENV['CGMINER_MANAGER_PID_FILE'] = '/tmp/cgminer-manager-nope.pid'
          code, _stdout, stderr = capture_run(['doctor'])
          expect(code).to eq(1)
          expect(stderr).to include('pid file configured but missing')
        end
      end
    end
  end
end
