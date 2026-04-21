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
end
