# frozen_string_literal: true

require "semian/adapter"
require "active_record"
require "active_record/connection_adapters/trilogy_adapter"

module ActiveRecord
  module ConnectionAdapters
    class TrilogyAdapter
      ActiveRecord::ActiveRecordError.include(::Semian::AdapterError)

      class SemianError < ConnectionNotEstablished
        def initialize(semian_identifier, *args)
          super(*args)
          @semian_identifier = semian_identifier
        end
      end

      ResourceBusyError = Class.new(SemianError)
      CircuitOpenError = Class.new(SemianError)
    end
  end
end

module Semian
  module ActiveRecordTrilogyAdapter
    include Semian::Adapter

    ResourceBusyError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::ResourceBusyError
    CircuitOpenError = ::ActiveRecord::ConnectionAdapters::TrilogyAdapter::CircuitOpenError

    attr_reader :raw_semian_options, :semian_identifier

    def initialize(*options)
      *, config = options
      config = config.dup
      @raw_semian_options = config.delete(:semian)
      @semian_identifier = begin
        name = semian_options && semian_options[:name]
        unless name
          host = config[:host] || "localhost"
          port = config[:port] || 3306
          name = "#{host}:#{port}"
        end
        :"mysql_#{name}"
      end
      super
    end

    def raw_execute(sql, *)
      if query_allowlisted?(sql)
        super
      else
        acquire_semian_resource(adapter: :trilogy_adapter, scope: :query) do
          super
        end
      end
    end
    ruby2_keywords :raw_execute

    def active?
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :ping) do
        super
      end
    rescue ResourceBusyError, CircuitOpenError
      false
    end

    def with_resource_timeout(temp_timeout)
      if connection.nil?
        prev_read_timeout = @config[:read_timeout] || 0
        @config.merge!(read_timeout: temp_timeout) # Create new client with temp_timeout for read timeout
      else
        prev_read_timeout = connection.read_timeout
        connection.read_timeout = temp_timeout
      end
      yield
    ensure
      @config.merge!(read_timeout: prev_read_timeout)
      connection&.read_timeout = prev_read_timeout
    end

    private

    def resource_exceptions
      [
        ActiveRecord::AdapterTimeout,
        ActiveRecord::ConnectionFailed,
        ActiveRecord::ConnectionNotEstablished,
      ]
    end

    # TODO: share this with Mysql2
    QUERY_ALLOWLIST = %r{\A(?:/\*.*?\*/)?\s*(ROLLBACK|COMMIT|RELEASE\s+SAVEPOINT)}i

    def query_allowlisted?(sql, *)
      QUERY_ALLOWLIST.match?(sql)
    rescue ArgumentError
      return false unless sql.valid_encoding?

      raise
    end

    def connect(*args)
      acquire_semian_resource(adapter: :trilogy_adapter, scope: :connection) do
        super
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::TrilogyAdapter.prepend(Semian::ActiveRecordTrilogyAdapter)
