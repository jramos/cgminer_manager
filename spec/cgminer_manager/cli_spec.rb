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
        expect(stderr).to include('usage: cgminer_manager {run|doctor|version}')
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
                        monitor_timeout: 2000)
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
        before do
          allow(client).to receive(:miners).and_return(miners: [{ id: '127.0.0.1:4028' }])
          allow(miner).to receive(:available?).and_return(true)
        end

        it 'reports DISABLED when CGMINER_MANAGER_ADMIN_AUTH=off' do
          original = ENV.fetch('CGMINER_MANAGER_ADMIN_AUTH', nil)
          ENV['CGMINER_MANAGER_ADMIN_AUTH'] = 'off'
          _code, stdout, _stderr = capture_run(['doctor'])
          expect(stdout).to include('admin auth: DISABLED')
        ensure
          original ? ENV['CGMINER_MANAGER_ADMIN_AUTH'] = original : ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
        end

        it 'reports "required (credentials configured)" when the hatch is absent' do
          original = ENV.fetch('CGMINER_MANAGER_ADMIN_AUTH', nil)
          ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
          _code, stdout, _stderr = capture_run(['doctor'])
          expect(stdout).to include('admin auth: required (credentials configured)')
        ensure
          original ? ENV['CGMINER_MANAGER_ADMIN_AUTH'] = original : ENV.delete('CGMINER_MANAGER_ADMIN_AUTH')
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
    end
  end
end
