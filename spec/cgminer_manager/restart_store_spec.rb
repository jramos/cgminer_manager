# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe CgminerManager::RestartStore do
  let(:tmpdir) { Dir.mktmpdir }
  let(:path) { File.join(tmpdir, 'restart_schedules.json') }
  let(:store) { described_class.new(path) }

  let(:schedule) do
    CgminerManager::RestartSchedule.new(
      miner_id: '127.0.0.1:4028', enabled: true, time_utc: '04:00',
      last_restart_at: nil, last_scheduled_date_utc: nil
    )
  end

  after { FileUtils.remove_entry(tmpdir) }

  describe '#load' do
    it 'returns an empty hash when the file is missing' do
      expect(store.load).to eq({})
    end

    it 'returns an empty hash and logs when JSON is malformed' do
      File.write(path, '{this is not json')
      allow(CgminerManager::Logger).to receive(:warn)
      expect(store.load).to eq({})
      expect(CgminerManager::Logger).to have_received(:warn).with(
        hash_including(event: 'restart.store.load_failed')
      )
    end

    it 'returns an empty hash when "schedules" is missing' do
      File.write(path, '{"version": 1}')
      expect(store.load).to eq({})
    end

    it 'skips malformed entries and keeps the rest' do
      File.write(path, JSON.generate(schedules: [
                                       schedule.to_h,
                                       { 'miner_id' => '', 'enabled' => true, 'time_utc' => '04:00' }
                                     ]))
      allow(CgminerManager::Logger).to receive(:warn)
      result = store.load
      expect(result.keys).to eq(['127.0.0.1:4028'])
      expect(CgminerManager::Logger).to have_received(:warn).with(
        hash_including(event: 'restart.store.entry_skipped')
      )
    end
  end

  describe '#update' do
    it 'persists a new schedule and returns it' do
      result = store.update('127.0.0.1:4028') { |_existing| schedule }
      expect(result).to eq(schedule)
      expect(store.load).to eq('127.0.0.1:4028' => schedule)
    end

    it 'yields the existing schedule when present' do
      store.replace('127.0.0.1:4028' => schedule)
      yielded = nil
      store.update('127.0.0.1:4028') do |existing|
        yielded = existing
        schedule.with(enabled: false, time_utc: nil)
      end
      expect(yielded).to eq(schedule)
    end

    it 'raises when the block returns a non-RestartSchedule' do
      expect { store.update('127.0.0.1:4028') { 'oops' } }
        .to raise_error(ArgumentError, /RestartSchedule/)
    end

    it 'creates the parent directory if missing' do
      nested = File.join(tmpdir, 'nested', 'dir', 'restart_schedules.json')
      nested_store = described_class.new(nested)
      nested_store.update('127.0.0.1:4028') { |_| schedule }
      expect(File.exist?(nested)).to be(true)
    end

    it 'leaves no .tmp file behind after a successful save' do
      store.update('127.0.0.1:4028') { |_| schedule }
      expect(File.exist?("#{path}.tmp")).to be(false)
      expect(File.exist?(path)).to be(true)
    end
  end

  describe '#replace' do
    it 'overwrites the whole file atomically' do
      store.replace('127.0.0.1:4028' => schedule)
      expect(store.load).to eq('127.0.0.1:4028' => schedule)
      expect(File.exist?("#{path}.tmp")).to be(false)
    end
  end

  describe 'concurrent updates' do
    it 'serializes via the mutex so neither write is lost' do
      store.replace('a' => schedule.with(miner_id: 'a'),
                    'b' => schedule.with(miner_id: 'b'))

      threads = []
      threads << Thread.new do
        store.update('a') do |existing|
          sleep 0.01 # widen the race window
          existing.with(time_utc: '05:00')
        end
      end
      threads << Thread.new do
        store.update('b') { |existing| existing.with(time_utc: '06:00') }
      end
      threads.each(&:join)

      result = store.load
      expect(result['a'].time_utc).to eq('05:00')
      expect(result['b'].time_utc).to eq('06:00')
    end
  end

  describe 'JSON format on disk' do
    it 'wraps entries under "schedules" and writes pretty JSON' do
      store.update('127.0.0.1:4028') { |_| schedule }
      raw = File.read(path)
      parsed = JSON.parse(raw)
      expect(parsed).to have_key('schedules')
      expect(parsed['schedules']).to be_an(Array)
      expect(parsed['schedules'].first).to include(
        'miner_id' => '127.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '04:00'
      )
      # Pretty-printed (multi-line)
      expect(raw.lines.size).to be > 1
    end
  end
end
