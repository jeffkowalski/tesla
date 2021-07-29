#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'bundler/setup'
require 'tesla_api'
require 'yaml'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.log', 'tesla.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'tesla.yaml')

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end

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

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'record-status', 'record the current usage data to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('tesla', time_precision: 'ms')

    credentials[:accounts].each do |account|
      with_rescue([Faraday::ConnectionFailed, Faraday::ServerError, Faraday::SSLError], @logger) do |_try|
        # tesla_api = TeslaApi::Client.new(email: account[:username],
        #                                  client_id: credentials[:client_id],
        #                                  client_secret: credentials[:client_secret])
        # tesla_api.login!(account[:password])
        tesla_api = TeslaApi::Client.new(access_token: account[:access_token], refresh_token: account[:refresh_token])

        tesla_api.vehicles.each do |vehicle|
          with_rescue([Faraday::ClientError, Faraday::ConnectionFailed, Faraday::ServerError], @logger) do |_try|
            @logger.debug vehicle

            if vehicle.state != 'online'
              @logger.info "#{vehicle['display_name']} is #{vehicle.state}, not online"
              next
            end

            charge_state = vehicle.charge_state
            if charge_state.nil?
              @logger.warn "#{vehicle['display_name']} cannot be queried"
              next
            end

            @logger.info "#{vehicle['display_name']} is #{vehicle['state']}, #{charge_state['charging_state']} " \
                         "with a SOC of #{charge_state['battery_level']}% " \
                         "and an estimated range of #{charge_state['est_battery_range']} miles " \
                         "timestamp #{charge_state['timestamp']}"

            tags = { display_name: vehicle['display_name'].tr("'", '_') }
            timestamp = charge_state['timestamp']
            data = [{ series: 'est_battery_range', values: { value: charge_state['est_battery_range'].to_f }, tags: tags, timestamp: timestamp },
                    { series: 'state',             values: { value: vehicle['state'] },                       tags: tags, timestamp: timestamp }]
            data.push({ series: 'charging_state',  values: { value: charge_state['charging_state'] },         tags: tags, timestamp: timestamp }) if charge_state['charging_state']
            influxdb.write_points data unless options[:dry_run]
          end
        rescue Faraday::ClientError, Faraday::ConnectionFailed, Faraday::ServerError => e
          @logger.info "#{vehicle['display_name']} is unavailable, #{vehicle.state} #{e}"
        end
      end
    rescue Faraday::UnauthorizedError => e
      @logger.error "not authorized to access #{account[:username]} #{e}"
    rescue Faraday::ConnectionFailed, Faraday::ServerError => e
      @logger.info "vehicles for #{account[:username]} are unavailable #{e}"
    rescue StandardError => e
      @logger.error e
    end
  end
end

Tesla.start
