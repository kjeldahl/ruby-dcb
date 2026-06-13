require "json"

module DcbEventStore
  # Input validation constants and methods for event store operations.
  # These limits help prevent abuse and ensure data integrity.
  module Validation
    # Maximum length for event type strings
    MAX_TYPE_LENGTH = 255

    # Maximum length for individual tag strings
    MAX_TAG_LENGTH = 255

    # Maximum number of tags per event
    MAX_TAGS_COUNT = 100

    # Maximum size for event data (in bytes when serialized to JSON)
    MAX_DATA_SIZE = 1_000_000 # 1 MB

    # Valid characters for event types (alphanumeric, underscore, colon, dot, hyphen)
    TYPE_PATTERN = /\A[a-zA-Z][a-zA-Z0-9_:.-]*\z/

    # Valid characters for tags (printable ASCII except comma, brace, quote)
    # Tags can contain any characters that don't break PostgreSQL array syntax
    TAG_PATTERN = /\A[^,"{}]*\z/

    # Validation error for events
    class ValidationError < StandardError
      attr_reader :field, :message

      def initialize(field:, message:)
        @field = field
        @message = message
        super("#{field}: #{message}")
      end
    end

    # Validates event type
    def self.validate_type(type)
      type = type.to_s

      raise ValidationError.new(field: :type, message: "cannot be empty") if type.empty?

      if type.length > MAX_TYPE_LENGTH
        raise ValidationError.new(field: :type, message: "exceeds maximum length of #{MAX_TYPE_LENGTH} characters")
      end

      unless TYPE_PATTERN.match?(type)
        raise ValidationError.new(
          field: :type,
          message: "contains invalid characters (must start with a letter, then letters, digits, _, :, ., -)"
        )
      end

      type
    end

    # Validates event tags
    def self.validate_tags(tags)
      tags = Array(tags).map(&:to_s)

      if tags.length > MAX_TAGS_COUNT
        raise ValidationError.new(field: :tags, message: "exceeds maximum count of #{MAX_TAGS_COUNT} tags")
      end

      tags.each_with_index do |tag, index|
        if tag.length > MAX_TAG_LENGTH
          raise ValidationError.new(field: :tags,
                                    message: "tag ##{index} exceeds maximum length of #{MAX_TAG_LENGTH} characters")
        end

        next if TAG_PATTERN.match?(tag)

        raise ValidationError.new(
          field: :tags,
          message: "tag at index #{index} contains invalid characters (cannot contain commas, braces, or quotes)"
        )
      end

      tags.freeze
    end

    # Validates event data
    def self.validate_data(data)
      return {} if data.nil?

      raise ValidationError.new(field: :data, message: "must be a Hash") unless data.is_a?(Hash)

      # Check size when serialized
      json_data = JSON.generate(data)
      if json_data.bytesize > MAX_DATA_SIZE
        raise ValidationError.new(field: :data, message: "exceeds maximum size of #{MAX_DATA_SIZE} bytes")
      end

      data
    end

    # Validates an entire event
    def self.validate_event(type:, data:, tags:)
      validate_type(type)
      validate_data(data)
      validate_tags(tags)
    end
  end
end
