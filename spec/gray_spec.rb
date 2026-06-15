# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe Bi2zip::Gray do
  describe '.encode' do
    it 'matches the canonical 3-bit reflected Gray sequence' do
      expected = %w[000 001 011 010 110 111 101 100]
      actual = (0..7).map { |n| described_class.encode(format('%03b', n)) }
      expect(actual).to eq(expected)
    end
  end

  describe '.decode' do
    it 'inverts .encode across several widths' do
      [1, 8, 12, 16].each do |width|
        rng = Random.new(width * 100)
        20.times do
          n = rng.rand(0...(1 << width))
          bin = format("%0#{width}b", n)
          gray = described_class.encode(bin)
          expect(described_class.decode(gray)).to eq(bin), "width=#{width} n=#{n}"
        end
      end
    end

    it 'round-trips for every value at small widths' do
      [1, 4, 8].each do |width|
        (0...(1 << width)).each do |n|
          bin = format("%0#{width}b", n)
          expect(described_class.decode(described_class.encode(bin))).to eq(bin)
        end
      end
    end
  end
end
