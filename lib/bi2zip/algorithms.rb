# frozen_string_literal: true

require_relative 'gray'

module Bi2zip
  # Six invertible per-column transforms used by the compressor. Each method
  # maps a bit-string of length PARTS to a bit-string of the same length, and
  # has a paired inverse such that reverse(name, forward(name, a)) == a.
  #
  # IDs and ALL are fixed: they form the rules-file header byte (algorithm ID
  # in the high nibble) and the deterministic tie-break order during pre-scan.
  module Algorithms
    ALL = %i[eq inv lshift rshift lgray rgray].freeze

    ID = {
      eq: 0,
      inv: 1,
      lshift: 2,
      rshift: 3,
      lgray: 4,
      rgray: 5,
    }.freeze

    BY_ID = ID.invert.freeze

    module_function

    def forward(name, column)
      case name
      when :eq then column
      when :inv then column.tr('01', '10')
      when :lshift then rotate_left(column)
      when :rshift then rotate_right(column)
      when :lgray then Gray.encode(column)
      when :rgray then Gray.decode(column)
      else raise ArgumentError, "unknown algorithm: #{name.inspect}"
      end
    end

    def reverse(name, column)
      case name
      when :eq then column
      when :inv then column.tr('01', '10')
      when :lshift then rotate_right(column)
      when :rshift then rotate_left(column)
      when :lgray then Gray.decode(column)
      when :rgray then Gray.encode(column)
      else raise ArgumentError, "unknown algorithm: #{name.inspect}"
      end
    end

    def name_for(id)
      BY_ID[id] || raise(ArgumentError, "unknown algorithm id: #{id.inspect}")
    end

    def rotate_left(column)
      return column if column.length <= 1

      "#{column[1..]}#{column[0]}"
    end
    private_class_method :rotate_left

    def rotate_right(column)
      return column if column.length <= 1

      "#{column[-1]}#{column[0...-1]}"
    end
    private_class_method :rotate_right
  end
end
