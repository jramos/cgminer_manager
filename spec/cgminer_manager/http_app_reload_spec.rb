# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe CgminerManager::HttpApp, '.reload_miners!' do # rubocop:disable RSpec/SpecFilePathFormat
  let(:dir)  { Dir.mktmpdir }
  let(:path) { File.join(dir, 'miners.yml') }

  before do
    File.write(path, "- host: 10.0.0.1\n  port: 4028\n")
    described_class.configure_for_test!(
      monitor_url: 'http://example',
      miners_file: path
    )
  end

  after { FileUtils.rm_rf(dir) }

  it 'swaps configured_miners with the freshly parsed file' do
    File.write(path, "- host: 10.0.0.2\n  port: 4028\n  label: swap\n")
    count = described_class.reload_miners!
    expect(count).to eq(1)
    expect(described_class.settings.configured_miners)
      .to eq([['10.0.0.2', 4028, 'swap'].freeze].freeze)
  end

  it 'keeps old miners and returns nil when YAML is malformed' do
    old = described_class.settings.configured_miners
    File.write(path, 'not: [valid')
    expect(described_class.reload_miners!).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end

  it 'keeps old miners when file goes missing' do
    old = described_class.settings.configured_miners
    File.unlink(path)
    expect(described_class.reload_miners!).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end

  it 'keeps old miners when validation fails (wrong shape)' do
    old = described_class.settings.configured_miners
    File.write(path, "just-a-string\n")
    expect(described_class.reload_miners!).to be_nil
    expect(described_class.settings.configured_miners).to equal(old)
  end
end
