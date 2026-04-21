# frozen_string_literal: true

require 'tmpdir'

RSpec.describe CgminerManager::Config do
  let(:miners_file) do
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  let(:env_base) do
    {
      'CGMINER_MONITOR_URL' => 'http://localhost:9292',
      'MINERS_FILE' => miners_file,
      'SESSION_SECRET' => 'x' * 64,
      'CGMINER_MANAGER_ADMIN_AUTH' => 'off'
    }
  end

  describe '.from_env' do
    it 'parses a fully-populated env into a Config' do
      config = described_class.from_env(env_base)

      expect(config.monitor_url).to eq('http://localhost:9292')
      expect(config.miners_file).to eq(miners_file)
      expect(config.port).to eq(3000)
      expect(config.bind).to eq('127.0.0.1')
      expect(config.log_format).to eq('text')
      expect(config.log_level).to eq('info')
      expect(config.stale_threshold_seconds).to eq(300)
      expect(config.shutdown_timeout).to eq(10)
    end

    it 'raises ConfigError when CGMINER_MONITOR_URL missing' do
      expect { described_class.from_env(env_base.merge('CGMINER_MONITOR_URL' => nil).compact) }
        .to raise_error(CgminerManager::ConfigError, /CGMINER_MONITOR_URL/)
    end

    it 'raises ConfigError when miners file missing' do
      expect { described_class.from_env(env_base.merge('MINERS_FILE' => '/no/such/file')) }
        .to raise_error(CgminerManager::ConfigError, /miners_file/)
    end

    it 'raises ConfigError when log_level invalid' do
      expect { described_class.from_env(env_base.merge('LOG_LEVEL' => 'trace')) }
        .to raise_error(CgminerManager::ConfigError, /log_level/)
    end

    it 'raises ConfigError when SESSION_SECRET unset in production' do
      env = env_base.merge('RACK_ENV' => 'production').tap { |h| h.delete('SESSION_SECRET') }
      expect { described_class.from_env(env) }
        .to raise_error(CgminerManager::ConfigError, /SESSION_SECRET/)
    end

    it 'accepts numeric env values and coerces them' do
      config = described_class.from_env(env_base.merge(
                                          'PORT' => '8080',
                                          'STALE_THRESHOLD_SECONDS' => '600'
                                        ))
      expect(config.port).to eq(8080)
      expect(config.stale_threshold_seconds).to eq(600)
    end

    it 'raises ConfigError when PORT is not an integer' do
      expect { described_class.from_env(env_base.merge('PORT' => 'abc')) }
        .to raise_error(CgminerManager::ConfigError, /PORT/)
    end
  end

  describe '.from_env boot-time admin-auth enforcement' do
    let(:auth_env_base) { env_base.except('CGMINER_MANAGER_ADMIN_AUTH') }

    it 'raises ConfigError when admin creds are missing and the escape hatch is unset' do
      expect { described_class.from_env(auth_env_base) }
        .to raise_error(CgminerManager::ConfigError, /admin auth is required/i)
    end

    it 'accepts the escape hatch set via CGMINER_MANAGER_ADMIN_AUTH=off' do
      expect { described_class.from_env(auth_env_base.merge('CGMINER_MANAGER_ADMIN_AUTH' => 'off')) }
        .not_to raise_error
    end

    it 'accepts credentials via CGMINER_MANAGER_ADMIN_USER + CGMINER_MANAGER_ADMIN_PASSWORD' do
      expect do
        described_class.from_env(auth_env_base.merge(
                                   'CGMINER_MANAGER_ADMIN_USER' => 'operator',
                                   'CGMINER_MANAGER_ADMIN_PASSWORD' => 's3cret'
                                 ))
      end.not_to raise_error
    end

    it 'raises ConfigError when only one of user/pass is set' do
      expect do
        described_class.from_env(auth_env_base.merge('CGMINER_MANAGER_ADMIN_USER' => 'operator'))
      end.to raise_error(CgminerManager::ConfigError, /admin auth is required/i)
    end
  end

  describe '#load_miners' do
    it 'yields [host, port] pairs' do
      config = described_class.from_env(env_base)
      expect(config.load_miners).to eq([['127.0.0.1', 4028]])
    end

    it 'defaults port to 4028 if missing in YAML' do
      File.write(miners_file, "- host: 10.0.0.5\n")
      config = described_class.from_env(env_base)
      expect(config.load_miners).to eq([['10.0.0.5', 4028]])
    end
  end
end
