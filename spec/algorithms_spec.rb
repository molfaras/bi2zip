# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::Algorithms do
  describe 'ALL and ID' do
    it 'covers exactly ALL with unique IDs that fit in 4 bits' do
      expect(described_class::ID.keys).to match_array(described_class::ALL)
      ids = described_class::ID.values
      expect(ids).to eq(ids.uniq)
      expect(ids).to all(be_between(0, 15))
    end

    it 'exposes a reverse mapping by ID' do
      described_class::ID.each do |name, id|
        expect(described_class.name_for(id)).to eq(name)
      end
    end

    it 'raises on unknown id' do
      expect { described_class.name_for(99) }.to raise_error(ArgumentError, /unknown algorithm id/)
    end
  end

  describe 'forward/reverse round-trip' do
    [1, 8, 12, 16].each do |width|
      described_class::ALL.each do |name|
        it "round-trips #{name} at width #{width} for 100 random columns" do
          rng = Random.new(name.hash ^ width)
          100.times do
            col = format("%0#{width}b", rng.rand(0...(1 << width)))
            forward = described_class.forward(name, col)
            expect(described_class.reverse(name, forward)).to eq(col)
          end
        end
      end
    end
  end

  describe 'purity' do
    described_class::ALL.each do |name|
      it "does not mutate the input column for #{name}" do
        col = '101011001100'
        snapshot = col.dup
        described_class.forward(name, col)
        described_class.reverse(name, col)
        expect(col).to eq(snapshot)
      end
    end
  end

  describe 'specific transforms' do
    it 'eq is identity' do
      expect(described_class.forward(:eq, '1100')).to eq('1100')
    end

    it 'inv flips every bit' do
      expect(described_class.forward(:inv, '1100')).to eq('0011')
      expect(described_class.reverse(:inv, '0011')).to eq('1100')
    end

    it 'lshift rotates left by one' do
      expect(described_class.forward(:lshift, '1000')).to eq('0001')
      expect(described_class.reverse(:lshift, '0001')).to eq('1000')
    end

    it 'rshift rotates right by one' do
      expect(described_class.forward(:rshift, '0001')).to eq('1000')
      expect(described_class.reverse(:rshift, '1000')).to eq('0001')
    end

    it 'lgray encodes binary to gray on forward' do
      expect(described_class.forward(:lgray, '100')).to eq(Bi2zip::Gray.encode('100'))
    end

    it 'rgray decodes gray to binary on forward' do
      expect(described_class.forward(:rgray, '110')).to eq(Bi2zip::Gray.decode('110'))
    end
  end

  it 'raises on an unknown algorithm name' do
    expect { described_class.forward(:nope, '00') }.to raise_error(ArgumentError, /unknown algorithm/)
    expect { described_class.reverse(:nope, '00') }.to raise_error(ArgumentError, /unknown algorithm/)
  end
end
