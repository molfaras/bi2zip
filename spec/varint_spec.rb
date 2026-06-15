# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::Varint do
  describe '.encode + .decode round-trip' do
    [0, 1, 127, 128, 16_383, 16_384, 2**32, 2**62].each do |n|
      it "round-trips #{n}" do
        encoded = described_class.encode(n)
        value, cursor = described_class.decode(encoded, 0)
        expect(value).to eq(n)
        expect(cursor).to eq(encoded.bytesize)
      end
    end
  end

  it 'rejects negative values on encode' do
    expect { described_class.encode(-1) }.to raise_error(ArgumentError, /non-negative/)
  end

  it 'raises on truncated varint (continuation bit set at EOF)' do
    expect { described_class.decode("\x80".b, 0) }.to raise_error(ArgumentError, /truncated varint/)
  end

  it 'raises when continuation bytes exceed MAX_BYTES' do
    bogus = ("\x80".b * (described_class::MAX_BYTES + 1))
    expect { described_class.decode(bogus, 0) }
      .to raise_error(ArgumentError, /exceeds.*bytes/)
  end
end
