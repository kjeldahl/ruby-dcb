module DcbEventStore
  class Upcaster
    def initialize
      @transformers = {}
    end

    def register(event_type, from_version:, &block)
      @transformers[[event_type, from_version]] = block
    end

    def upcast(type, data, version)
      loop do
        transformer = @transformers[[type, version]]
        break unless transformer

        data = transformer.call(data)
        version += 1
      end
      [data, version]
    end
  end
end
