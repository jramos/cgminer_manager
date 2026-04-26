# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable RSpec/MultipleMemoizedHelpers
RSpec.describe CgminerManager::RestartScheduler do
  let(:tmpdir) { Dir.mktmpdir }
  let(:store) { CgminerManager::RestartStore.new(File.join(tmpdir, 'restart_schedules.json')) }
  let(:configured_miners) { [['127.0.0.1', 4028, 'rig-A']] }
  let(:fake_miner) { instance_double(CgminerApiClient::Miner) }
  let(:fixed_now) { Time.utc(2026, 4, 24, 4, 0, 30) }
  let(:schedule) do
    CgminerManager::RestartSchedule.build(
      miner_id: '127.0.0.1:4028', enabled: true, time_utc: '04:00',
      last_restart_at: nil, last_scheduled_date_utc: nil
    )
  end
  let(:scheduler) do
    described_class.new(store: store,
                        configured_miners_provider: -> { configured_miners },
                        clock: -> { fixed_now },
                        miner_factory: ->(_h, _p) { fake_miner })
  end

  before { allow(fake_miner).to receive(:restart).and_return(true) }
  after { FileUtils.remove_entry(tmpdir) }

  describe '#tick' do
    context 'when in window and never fired' do
      before { store.replace(schedule.miner_id => schedule) }

      it 'fires restart and persists last_restart_at + last_scheduled_date_utc' do
        scheduler.tick
        expect(fake_miner).to have_received(:restart).once
        persisted = store.load[schedule.miner_id]
        expect(persisted.last_scheduled_date_utc).to eq('2026-04-24')
        expect(persisted.last_restart_at).to start_with('2026-04-24T04:00:30')
      end
    end

    context 'when in window and already fired today (date dedupe)' do
      before do
        store.replace(schedule.miner_id => schedule.with(last_scheduled_date_utc: '2026-04-24'))
      end

      it 'does not fire' do
        scheduler.tick
        expect(fake_miner).not_to have_received(:restart)
      end
    end

    context 'when in window and fired yesterday' do
      before do
        store.replace(schedule.miner_id => schedule.with(
          last_scheduled_date_utc: '2026-04-23',
          last_restart_at: '2026-04-23T04:00:14Z'
        ))
      end

      it 'fires (a new UTC day)' do
        scheduler.tick
        expect(fake_miner).to have_received(:restart).once
      end
    end

    context 'when out of window' do
      let(:fixed_now) { Time.utc(2026, 4, 24, 12, 0, 0) }

      before { store.replace(schedule.miner_id => schedule) }

      it 'does not fire' do
        scheduler.tick
        expect(fake_miner).not_to have_received(:restart)
      end
    end

    context 'when within ±2 minute window' do
      before { store.replace(schedule.miner_id => schedule) }

      [
        Time.utc(2026, 4, 24, 3, 58, 0),
        Time.utc(2026, 4, 24, 3, 59, 30),
        Time.utc(2026, 4, 24, 4, 0, 0),
        Time.utc(2026, 4, 24, 4, 1, 30),
        Time.utc(2026, 4, 24, 4, 2, 0)
      ].each do |t|
        it "fires when now=#{t.strftime('%H:%M:%S')}" do
          allow(scheduler).to receive(:tick).and_wrap_original do |orig, *args|
            orig.call(*args)
          end
          stub_now(t) { scheduler.tick }
          expect(fake_miner).to have_received(:restart)
        end
      end

      [
        Time.utc(2026, 4, 24, 3, 57, 0),
        Time.utc(2026, 4, 24, 4, 3, 0)
      ].each do |t|
        it "does NOT fire when now=#{t.strftime('%H:%M:%S')}" do
          stub_now(t) { scheduler.tick }
          expect(fake_miner).not_to have_received(:restart)
        end
      end
    end

    context 'when wrapping around midnight' do
      let(:fixed_now) { Time.utc(2026, 4, 24, 23, 59, 0) }

      before do
        store.replace(schedule.miner_id => schedule.with(time_utc: '00:00'))
      end

      it 'fires when now=23:59 and time_utc=00:00 (1 minute before)' do
        scheduler.tick
        expect(fake_miner).to have_received(:restart)
      end
    end

    context 'when schedule is disabled' do
      before do
        store.replace(schedule.miner_id => schedule.with(enabled: false, time_utc: '04:00'))
      end

      it 'does not fire' do
        scheduler.tick
        expect(fake_miner).not_to have_received(:restart)
      end
    end

    context 'when miner is not in configured_miners (orphan schedule)' do
      let(:configured_miners) { [] }

      before { store.replace(schedule.miner_id => schedule) }

      it 'does not fire' do
        scheduler.tick
        expect(fake_miner).not_to have_received(:restart)
      end
    end

    context 'when restart raises ConnectionError' do
      before do
        store.replace(schedule.miner_id => schedule)
        allow(fake_miner).to receive(:restart)
          .and_raise(CgminerApiClient::ConnectionError, 'connection refused')
        allow(CgminerManager::Logger).to receive(:error)
      end

      it 'logs restart.scheduled.failed and does not update last_scheduled_date_utc' do
        scheduler.tick
        expect(CgminerManager::Logger).to have_received(:error).with(
          hash_including(event: 'restart.scheduled.failed', miner: schedule.miner_id)
        )
        expect(store.load[schedule.miner_id].last_scheduled_date_utc).to be_nil
      end
    end

    context 'when restart raises a generic StandardError' do
      before do
        store.replace(schedule.miner_id => schedule)
        allow(fake_miner).to receive(:restart).and_raise(RuntimeError, 'boom')
        allow(CgminerManager::Logger).to receive(:error)
      end

      it 'logs and does not advance last_scheduled_date_utc' do
        scheduler.tick
        expect(CgminerManager::Logger).to have_received(:error).with(
          hash_including(event: 'restart.scheduled.failed')
        )
      end
    end
  end

  describe 'per-tick StandardError guard' do
    let(:scheduler) do
      described_class.new(store: store,
                          configured_miners_provider: -> { configured_miners },
                          clock: -> { raise 'tick exploded' },
                          miner_factory: ->(_h, _p) { fake_miner })
    end

    it 'logs restart.scheduler.tick_error and the thread keeps running' do
      store.replace(schedule.miner_id => schedule)
      allow(CgminerManager::Logger).to receive(:error)
      scheduler.start
      sleep 0.05
      scheduler.stop
      scheduler.join(2)
      expect(scheduler.thread.alive?).to be(false)
      expect(CgminerManager::Logger).to have_received(:error).with(
        hash_including(event: 'restart.scheduler.tick_error')
      ).at_least(:once)
    end
  end

  describe 'thread-top Exception guard' do
    # Raise a non-StandardError so the per-tick rescue does NOT catch it.
    # NoMemoryError descends from Exception, not StandardError. Without
    # the thread-top guard the scheduler would die silently.
    let(:scheduler) do
      described_class.new(store: store,
                          configured_miners_provider: -> { configured_miners },
                          clock: -> { raise NoMemoryError, 'simulated' },
                          miner_factory: ->(_h, _p) { fake_miner })
    end

    it 'logs restart.scheduler.crash and exits the thread cleanly' do
      store.replace(schedule.miner_id => schedule)
      allow(CgminerManager::Logger).to receive(:error)
      scheduler.start
      scheduler.join(2)
      expect(scheduler.thread.alive?).to be(false)
      expect(CgminerManager::Logger).to have_received(:error).with(
        hash_including(event: 'restart.scheduler.crash', error: 'NoMemoryError')
      )
    end
  end

  describe '#start / #stop lifecycle' do
    it 'spawns a thread that fires the scheduled restart and exits cleanly on stop' do
      store.replace(schedule.miner_id => schedule)
      scheduler.start
      40.times do
        break if RSpec::Mocks.space.proxy_for(fake_miner).instance_variable_get(:@messages_received)&.any?

        sleep 0.005
      end
      scheduler.stop
      scheduler.join(2)
      expect(scheduler.thread.alive?).to be(false)
      expect(fake_miner).to have_received(:restart)
    end
  end

  def stub_now(time)
    original_clock = scheduler.instance_variable_get(:@clock)
    scheduler.instance_variable_set(:@clock, -> { time })
    yield
  ensure
    scheduler.instance_variable_set(:@clock, original_clock)
  end
end
# rubocop:enable RSpec/MultipleMemoizedHelpers
