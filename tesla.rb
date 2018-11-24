#!/usr/bin/env ruby

require 'thor'
require 'logger'
require 'bundler/setup'
require 'tesla_api'
require 'yaml'
require 'influxdb'


LOGFILE = File.join(Dir.home, '.log', 'tesla.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'tesla.yaml')

class Tesla < Thor
  no_commands {
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
        FileUtils.touch logfile
        File.chmod 0644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to #{LOGFILE}"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"

  desc "record-status", "record the current usage data to database"
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    influxdb = InfluxDB::Client.new('tesla', time_precision: 'ms')

    credentials[:accounts].each { |account|
      tesla_api = TeslaApi::Client.new(account[:username], credentials[:client_id], credentials[:client_secret])
      tesla_api.login!(account[:password])
      vehicle = tesla_api.vehicles.first
      charge_state = vehicle.charge_state
      if charge_state.nil?
        $logger.warn "#{vehicle['display_name']} cannot be queried"
      else
        $logger.info "#{vehicle['display_name']} is #{charge_state['charging_state']} " +
                     "with a SOC of #{charge_state['battery_level']}% " +
                     "and an estimate range of #{charge_state['est_battery_range']} miles " +
                     "timestamp #{charge_state['timestamp']}"

        display_name = vehicle['display_name'].gsub("'", "_")
        data = {
          values: { value: charge_state['est_battery_range'].to_f },
          tags:   { display_name: display_name },
          timestamp: charge_state['timestamp']
        }
        influxdb.write_point('est_battery_range', data)  # millisecond precision
      end
    }
  end
end

Tesla.start
