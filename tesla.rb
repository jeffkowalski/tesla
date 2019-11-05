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
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'
  class_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"

  desc 'record-status', 'record the current usage data to database'
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('tesla', time_precision: 'ms')

    credentials[:accounts].each do |account|
      tesla_api = TeslaApi::Client.new(email: account[:username],
                                       access_token: nil,
                                       access_token_expires_at: nil,
                                       refresh_token: nil,
                                       client_id: credentials[:client_id],
                                       client_secret: credentials[:client_secret])
      tesla_api.login!(account[:password])
      vehicle = tesla_api.vehicles.first
      @logger.debug vehicle
      if vehicle.state == 'asleep'
        @logger.info "#{vehicle['display_name']} is asleep"
      else
        charge_state = vehicle.charge_state
        if charge_state.nil?
          @logger.warn "#{vehicle['display_name']} cannot be queried"
        else
          @logger.info "#{vehicle['display_name']} is #{vehicle['state']}, #{charge_state['charging_state']} " \
                       "with a SOC of #{charge_state['battery_level']}% " \
                       "and an estimated range of #{charge_state['est_battery_range']} miles " \
                       "timestamp #{charge_state['timestamp']}"

          display_name = vehicle['display_name'].tr("'", '_')
          data = {
            values: { value: charge_state['est_battery_range'].to_f },
            tags: { display_name: display_name },
            timestamp: charge_state['timestamp']
          }
          influxdb.write_point('est_battery_range', data) unless options[:dry_run] # millisecond precision
        end
      end
    end
  end
end

Tesla.start
