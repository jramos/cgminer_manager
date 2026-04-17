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
end
