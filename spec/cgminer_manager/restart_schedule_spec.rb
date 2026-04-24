# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CgminerManager::RestartSchedule do
  describe '.parse' do
    let(:base) do
      {
        'miner_id' => '127.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '04:00',
        'last_restart_at' => nil,
        'last_scheduled_date_utc' => nil
      }
    end

    it 'returns a RestartSchedule for a valid hash' do
      schedule = described_class.parse(base)
      expect(schedule.miner_id).to eq('127.0.0.1:4028')
      expect(schedule.enabled).to be(true)
      expect(schedule.time_utc).to eq('04:00')
      expect(schedule.last_restart_at).to be_nil
      expect(schedule.last_scheduled_date_utc).to be_nil
    end

    it 'accepts symbol keys' do
      schedule = described_class.parse(base.transform_keys(&:to_sym))
      expect(schedule.miner_id).to eq('127.0.0.1:4028')
    end

    it 'accepts disabled with nil time_utc' do
      schedule = described_class.parse(base.merge('enabled' => false, 'time_utc' => nil))
      expect(schedule.enabled).to be(false)
      expect(schedule.time_utc).to be_nil
    end

    it 'accepts disabled with a present time_utc (operator toggling off temporarily)' do
      schedule = described_class.parse(base.merge('enabled' => false))
      expect(schedule.time_utc).to eq('04:00')
    end

    it 'accepts ISO-8601 last_restart_at and YYYY-MM-DD last_scheduled_date_utc' do
      schedule = described_class.parse(base.merge(
                                         'last_restart_at' => '2026-04-23T04:00:14Z',
                                         'last_scheduled_date_utc' => '2026-04-23'
                                       ))
      expect(schedule.last_restart_at).to eq('2026-04-23T04:00:14Z')
      expect(schedule.last_scheduled_date_utc).to eq('2026-04-23')
    end

    it 'rejects empty miner_id' do
      expect { described_class.parse(base.merge('miner_id' => '')) }
        .to raise_error(described_class::InvalidError, /miner_id/)
    end

    it 'rejects non-string miner_id' do
      expect { described_class.parse(base.merge('miner_id' => 42)) }
        .to raise_error(described_class::InvalidError, /miner_id/)
    end

    it 'rejects non-boolean enabled' do
      expect { described_class.parse(base.merge('enabled' => 'true')) }
        .to raise_error(described_class::InvalidError, /enabled/)
    end

    it 'rejects 24:00' do
      expect { described_class.parse(base.merge('time_utc' => '24:00')) }
        .to raise_error(described_class::InvalidError, /time_utc/)
    end

    it 'rejects 4:00 (missing leading zero)' do
      expect { described_class.parse(base.merge('time_utc' => '4:00')) }
        .to raise_error(described_class::InvalidError, /time_utc/)
    end

    it 'rejects 04:60' do
      expect { described_class.parse(base.merge('time_utc' => '04:60')) }
        .to raise_error(described_class::InvalidError, /time_utc/)
    end

    it 'rejects nil time_utc when enabled' do
      expect { described_class.parse(base.merge('time_utc' => nil)) }
        .to raise_error(described_class::InvalidError, /time_utc/)
    end

    it 'rejects malformed last_scheduled_date_utc' do
      expect { described_class.parse(base.merge('last_scheduled_date_utc' => '04/23/2026')) }
        .to raise_error(described_class::InvalidError, /last_scheduled_date_utc/)
    end

    it 'rejects a non-Hash argument' do
      expect { described_class.parse('not a hash') }
        .to raise_error(described_class::InvalidError, /Hash/)
    end
  end

  describe '#to_h' do
    it 'returns a string-keyed hash with all fields' do
      schedule = described_class.new(
        miner_id: '10.0.0.1:4028', enabled: true, time_utc: '03:30',
        last_restart_at: '2026-04-24T03:30:00Z', last_scheduled_date_utc: '2026-04-24'
      )
      expect(schedule.to_h).to eq(
        'miner_id' => '10.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '03:30',
        'last_restart_at' => '2026-04-24T03:30:00Z',
        'last_scheduled_date_utc' => '2026-04-24'
      )
    end

    it 'round-trips through parse' do
      original = described_class.new(
        miner_id: '10.0.0.1:4028', enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil
      )
      expect(described_class.parse(original.to_h)).to eq(original)
    end
  end
end
