require 'eventmachine'
require 'servolux'

require 'remote_syslog/eventmachine_reader'
require 'remote_syslog/file_tail_reader'
require 'remote_syslog/glob_watch'
require 'remote_syslog/message_generator'
require 'remote_syslog/udp_endpoint'
require 'remote_syslog/tls_endpoint'

module RemoteSyslog
  class Agent < Servolux::Server
    # Who should we connect to?
    attr_accessor :destination_host, :destination_port

    # Should use TLS?
    attr_accessor :tls

    # TLS settings
    attr_accessor :client_cert_chain, :client_private_key, :server_cert

    # syslog defaults
    attr_accessor :facility, :severity, :hostname

    # Other settings
    attr_accessor :strip_color, :parse_fields, :exclude_pattern

    # Files
    attr_reader :files

    # How often should we check for new files?
    attr_accessor :glob_check_interval

    # Should we use eventmachine to tail?
    attr_accessor :eventmachine_tail

    def initialize(options = {})
      @files = []
      @glob_check_interval = 60
      @eventmachine_tail = options.fetch(:eventmachine_tail, true)

      logger = options[:logger] || Logger.new(STDERR)

      super('remote_syslog', :logger => logger, :pid_file => options[:pid_file])
    end

    def files=(files)
      @files = [ @files, files ].flatten.compact.uniq
    end

    def watch_file(file)
      if eventmachine_tail
        RemoteSyslog::EventMachineReader.new(file,
          :callback => @message_generator.method(:transmit),
          :logger => logger)
      else
        RemoteSyslog::FileTailReader.new(file,
          :callback => @message_generator.method(:transmit),
          :logger => logger)
      end
    end

    def run
      EventMachine.run do
        EM.error_handler do |e|
          logger.error "Unhandled EventMachine Exception: #{e.class}: #{e.message}:\n\t#{e.backtrace.join("\n\t")}"
        end

        if @tls
          max_message_size = 10240

          connection = TlsEndpoint.new(@destination_host, @destination_port,
            :client_cert_chain => @client_cert_chain,
            :client_private_key => @client_private_key,
            :server_cert => @server_cert,
            :logger => logger)
        else
          max_message_size = 1024
          connection = UdpEndpoint.new(@destination_host, @destination_port,
            :logger => logger)
        end

        @message_generator = RemoteSyslog::MessageGenerator.new(connection, 
          :facility => @facility, :severity => @severity, 
          :strip_color => @strip_color, :hostname => @hostname, 
          :parse_fields => @parse_fields, :exclude_pattern => @exclude_pattern,
          :max_message_size => max_message_size)

        files.each do |file|
          RemoteSyslog::GlobWatch.new(file, @glob_check_interval, 
            method(:watch_file))
        end
      end
    end

    def before_stopping
      EM.stop
    end
  end
end