# frozen_string_literal: true

RSpec.describe CgminerManager::ViewMiner do
  describe '.build' do
    it 'yields .host, .port (Integer), .available?, and .to_s' do
      vm = described_class.build('h', 4028, true)
      expect(vm.host).to eq('h')
      expect(vm.port).to eq(4028)
      expect(vm.port).to be_a(Integer)
      expect(vm.available?).to be(true)
      expect(vm.to_s).to eq('h:4028')
    end

    it 'coerces string ports to Integer' do
      vm = described_class.build('h', '4028', true)
      expect(vm.port).to eq(4028)
      expect(vm.port).to be_a(Integer)
    end

    it 'supports value equality (needed by uniq!)' do
      a = described_class.build('h', 4028, true)
      b = described_class.build('h', 4028, true)
      expect(a).to eq(b)
      expect([a, b].uniq.size).to eq(1)
    end
  end
end

RSpec.describe CgminerManager::ViewMinerPool do
  let(:available)   { CgminerManager::ViewMiner.build('up',   4028, true) }
  let(:unavailable) { CgminerManager::ViewMiner.build('down', 4028, false) }

  it 'partitions into available_miners / unavailable_miners' do
    pool = described_class.new(miners: [available, unavailable])
    expect(pool.available_miners).to eq([available])
    expect(pool.unavailable_miners).to eq([unavailable])
  end
end
