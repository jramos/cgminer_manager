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
      schedule = described_class.build(
        miner_id: '10.0.0.1:4028', enabled: true, time_utc: '03:30',
        last_restart_at: '2026-04-24T03:30:00Z', last_scheduled_date_utc: '2026-04-24'
      )
      expect(schedule.to_h).to eq(
        'miner_id' => '10.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '03:30',
        'last_restart_at' => '2026-04-24T03:30:00Z',
        'last_scheduled_date_utc' => '2026-04-24',
        'drained' => false,
        'drained_at' => nil,
        'drained_by' => nil,
        'auto_resume_attempt_count' => 0,
        'auto_resume_last_attempt_at' => nil
      )
    end

    it 'round-trips through parse' do
      original = described_class.build(
        miner_id: '10.0.0.1:4028', enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil
      )
      expect(described_class.parse(original.to_h)).to eq(original)
    end
  end

  describe 'drain mode (v1.8.0+)' do
    let(:base) do
      {
        'miner_id' => '127.0.0.1:4028',
        'enabled' => true,
        'time_utc' => '04:00',
        'last_restart_at' => nil,
        'last_scheduled_date_utc' => nil
      }
    end

    it 'defaults drained=false on .build when not specified' do
      s = described_class.build(miner_id: 'x:4028', enabled: false, time_utc: nil,
                                last_restart_at: nil, last_scheduled_date_utc: nil)
      expect(s.drained).to be(false)
      expect(s.draining?).to be(false)
      expect(s.auto_resume_attempt_count).to eq(0)
    end

    it 'returns true from #draining? when drained=true' do
      s = described_class.build(miner_id: 'x:4028', enabled: false, time_utc: nil,
                                last_restart_at: nil, last_scheduled_date_utc: nil,
                                drained: true, drained_at: '2026-04-26T12:00:00.000Z',
                                drained_by: 'op')
      expect(s.draining?).to be(true)
    end

    it 'parses a hash that includes the drain fields' do
      s = described_class.parse(base.merge(
                                  'drained' => true,
                                  'drained_at' => '2026-04-26T12:00:00.000Z',
                                  'drained_by' => 'admin',
                                  'auto_resume_attempt_count' => 3,
                                  'auto_resume_last_attempt_at' => '2026-04-26T12:01:00.000Z'
                                ))
      expect(s.drained).to be(true)
      expect(s.drained_at).to eq('2026-04-26T12:00:00.000Z')
      expect(s.drained_by).to eq('admin')
      expect(s.auto_resume_attempt_count).to eq(3)
      expect(s.auto_resume_last_attempt_at).to eq('2026-04-26T12:01:00.000Z')
    end

    it 'is back-compat with pre-v1.8.0 JSON files (no drain fields present)' do
      s = described_class.parse(base)
      expect(s.drained).to be(false)
      expect(s.drained_at).to be_nil
      expect(s.drained_by).to be_nil
      expect(s.auto_resume_attempt_count).to eq(0)
      expect(s.auto_resume_last_attempt_at).to be_nil
    end

    it 'round-trips a drained schedule through to_h + parse' do
      original = described_class.build(
        miner_id: 'x:4028', enabled: false, time_utc: nil,
        last_restart_at: nil, last_scheduled_date_utc: nil,
        drained: true, drained_at: '2026-04-26T12:00:00.000Z', drained_by: 'op',
        auto_resume_attempt_count: 2, auto_resume_last_attempt_at: '2026-04-26T12:30:00.000Z'
      )
      expect(described_class.parse(original.to_h)).to eq(original)
    end

    it 'rejects drained=true with nil drained_at' do
      expect { described_class.parse(base.merge('drained' => true, 'drained_at' => nil)) }
        .to raise_error(described_class::InvalidError, /drained_at must be a non-empty ISO8601/)
    end

    it 'rejects drained=false with non-nil drained_at (the two must move together)' do
      expect { described_class.parse(base.merge('drained' => false, 'drained_at' => '2026-04-26T12:00:00.000Z')) }
        .to raise_error(described_class::InvalidError, /drained_at must be nil when drained=false/)
    end

    it 'rejects truthy-not-true drained value (defensive)' do
      expect { described_class.parse(base.merge('drained' => 'true', 'drained_at' => '2026-04-26T12:00:00.000Z')) }
        .to raise_error(described_class::InvalidError, /drained must be true or false/)
    end

    it 'rejects non-Integer auto_resume_attempt_count' do
      expect { described_class.parse(base.merge('auto_resume_attempt_count' => '3')) }
        .to raise_error(described_class::InvalidError, /auto_resume_attempt_count/)
    end

    it 'rejects negative auto_resume_attempt_count' do
      expect { described_class.parse(base.merge('auto_resume_attempt_count' => -1)) }
        .to raise_error(described_class::InvalidError, /auto_resume_attempt_count/)
    end
  end
end
