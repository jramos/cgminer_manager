# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe CgminerManager::CLI, 'reload' do # rubocop:disable RSpec/DescribeMethod
  let(:dir)         { Dir.mktmpdir }
  let(:miners_path) { File.join(dir, 'miners.yml') }
  let(:pid_path)    { File.join(dir, 'cgminer_manager.pid') }

  before do
    File.write(miners_path, "- host: 10.0.0.1\n  port: 4028\n")
    stub_const('ENV', ENV.to_h.merge(
                        'CGMINER_MONITOR_URL' => 'http://example',
                        'MINERS_FILE' => miners_path,
                        'CGMINER_MANAGER_PID_FILE' => pid_path,
                        'CGMINER_MANAGER_ADMIN_AUTH' => 'off',
                        'SESSION_SECRET' => 'x' * 64
                      ))
  end

  after { FileUtils.rm_rf(dir) }

  it 'sends SIGHUP to the recorded pid and returns 0' do
    File.write(pid_path, "#{Process.pid}\n")
    allow(Process).to receive(:kill).with(0, Process.pid).and_return(1)
    allow(Process).to receive(:kill).with('HUP', Process.pid).and_return(1)

    expect { expect(described_class.run(['reload'])).to eq(0) }
      .to output(/SIGHUP sent to pid/).to_stdout
    expect(Process).to have_received(:kill).with('HUP', Process.pid)
  end

  it 'returns 1 when the pid file is missing' do
    expect { expect(described_class.run(['reload'])).to eq(1) }
      .to output(/pid file not found/).to_stderr
  end

  it 'returns 1 when the pid is not running' do
    File.write(pid_path, "9999999\n")
    allow(Process).to receive(:kill).with(0, 9_999_999).and_raise(Errno::ESRCH)
    expect { expect(described_class.run(['reload'])).to eq(1) }
      .to output(/stale pid file/).to_stderr
  end

  it 'returns 2 when miners.yml is malformed (dry-run parse catches it)' do
    File.write(miners_path, 'not: [valid')
    File.write(pid_path, "#{Process.pid}\n")
    expect { expect(described_class.run(['reload'])).to eq(2) }
      .to output(/config error/).to_stderr
  end

  it 'returns 2 when CGMINER_MANAGER_PID_FILE is unset' do
    stub_const('ENV', ENV.to_h.merge('CGMINER_MANAGER_PID_FILE' => ''))
    expect { expect(described_class.run(['reload'])).to eq(2) }
      .to output(/CGMINER_MANAGER_PID_FILE not set/).to_stderr
  end
end
