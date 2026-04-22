# frozen_string_literal: true

require 'net/http'
require 'socket'

RSpec.describe 'full boot', type: :integration do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  def write_miners_file
    path = File.join(Dir.mktmpdir, 'miners.yml')
    File.write(path, "- host: 127.0.0.1\n  port: 4028\n")
    path
  end

  def spawn_server(miners_file)
    env = {
      'CGMINER_MONITOR_URL' => 'http://127.0.0.1:65501',
      'MINERS_FILE' => miners_file,
      'SESSION_SECRET' => 'x' * 64,
      'PORT' => '6123',
      'BIND' => '127.0.0.1',
      'SHUTDOWN_TIMEOUT' => '3'
    }
    spawn(env, 'bundle', 'exec', 'bin/cgminer_manager', 'run',
          chdir: File.expand_path('../..', __dir__))
  end

  def wait_for_bind!(host, port, timeout: 15)
    deadline = Time.now + timeout
    until Time.now >= deadline
      begin
        TCPSocket.new(host, port).close
        return
      rescue Errno::ECONNREFUSED
        Thread.pass
      end
    end
    raise 'server did not bind within deadline'
  end

  it 'starts the Server, serves /healthz, and stops gracefully' do
    pid = spawn_server(write_miners_file)
    wait_for_bind!('127.0.0.1', 6123)

    response = Net::HTTP.get_response(URI('http://127.0.0.1:6123/healthz'))
    expect(response.code.to_i).to eq(200).or eq(503)

    Process.kill('TERM', pid)
    _, status = Process.wait2(pid)
    expect(status.exitstatus).to eq(0)
  end

  # SIGHUP path: rewrite miners.yml, send SIGHUP to the spawned process,
  # and observe (1) the new miner visible via /api/v1/ping.json's
  # unavailable_miners count (both 127.0.0.1:* probes ECONNREFUSED
  # instantly) and (2) the expected reload.* events in captured stderr.
  # The stderr assertion is the regression guard against a future change
  # that silently swallows SIGHUP — e.g., Puma reinstalling its own HUP
  # trap between our install and the process boundary.
  it 'reloads miners on SIGHUP' do # rubocop:disable RSpec/ExampleLength
    dir         = Dir.mktmpdir
    miners_path = File.join(dir, 'miners.yml')
    pid_path    = File.join(dir, 'cm.pid')
    File.write(miners_path, "- host: 127.0.0.1\n  port: 4028\n")

    env = {
      'CGMINER_MONITOR_URL' => 'http://127.0.0.1:65501',
      'MINERS_FILE' => miners_path,
      'SESSION_SECRET' => 'x' * 64,
      'PORT' => '6124',
      'BIND' => '127.0.0.1',
      'SHUTDOWN_TIMEOUT' => '3',
      'CGMINER_MANAGER_PID_FILE' => pid_path,
      'CGMINER_MANAGER_ADMIN_AUTH' => 'off',
      'LOG_FORMAT' => 'json'
    }

    log_r, log_w = IO.pipe
    pid = spawn(env, 'bundle', 'exec', 'bin/cgminer_manager', 'run',
                chdir: File.expand_path('../..', __dir__),
                out: log_w, err: log_w)
    log_w.close

    begin
      wait_for_bind!('127.0.0.1', 6124)

      deadline = Time.now + 5
      sleep 0.05 until File.exist?(pid_path) || Time.now > deadline
      expect(File.read(pid_path).strip).to eq(pid.to_s)

      initial = JSON.parse(Net::HTTP.get(URI('http://127.0.0.1:6124/api/v1/ping.json')))
      expect(initial['available_miners'].to_i + initial['unavailable_miners'].to_i).to eq(1)

      File.write(miners_path,
                 "- host: 127.0.0.1\n  port: 4028\n" \
                 "- host: 127.0.0.1\n  port: 4029\n")
      Process.kill('HUP', pid)

      deadline = Time.now + 5
      total = 0
      until Time.now > deadline
        ping = JSON.parse(Net::HTTP.get(URI('http://127.0.0.1:6124/api/v1/ping.json')))
        total = ping['available_miners'].to_i + ping['unavailable_miners'].to_i
        break if total == 2

        sleep 0.1
      end
      expect(total).to eq(2)
    ensure
      Process.kill('TERM', pid) rescue nil # rubocop:disable Style/RescueModifier
      Process.wait(pid)
      logged = log_r.read
      log_r.close
      expect(logged).to match(/reload\.signal_received/)
      expect(logged).to match(/reload\.ok/)
      FileUtils.rm_rf(dir)
    end
  end
end
