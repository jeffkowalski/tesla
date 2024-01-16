#!/usr/bin/env ruby
# frozen_string_literal:true

require 'bundler/setup'
Bundler.require(:default)

class Tesla < RecorderBotBase
  desc 'refresh-access-token', 'refresh access tokens'
  def refresh_access_token
    @logger.info 'refreshing access tokens'

    credentials = load_credentials
    credentials[:accounts].each do |account|
      tesla_api = TeslaApi::Client.new(
        client_id:     credentials[:client_id],
        client_secret: credentials[:client_secret],
        email:         account[:username],
        access_token:  account[:access_token],
        refresh_token: account[:refresh_token]
      )
      tesla_api.refresh_access_token
      account[:access_token] = tesla_api.access_token
      account[:refresh_token] = tesla_api.refresh_token
    end
    store_credentials credentials
  end

  no_commands do
    def main
      credentials = load_credentials

      influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('tesla', time_precision: 'ms')

      soft_faults = [Faraday::ConnectionFailed, Faraday::ServerError, Faraday::SSLError]
      credentials[:accounts].each do |account|
        with_rescue(soft_faults, @logger) do |_try|
          vehicles =
            begin
              tesla_api = TeslaApi::Client.new(
                client_id:     credentials[:client_id],
                client_secret: credentials[:client_secret],
                email:         account[:username],
                access_token:  account[:access_token],
                refresh_token: account[:refresh_token]
              )
              tesla_api.vehicles
            rescue Faraday::UnauthorizedError => e
              @logger.warn "not authorized to access #{account[:username]} : #{e} #{e.response[:body]}"
              if e.response[:body].include? 'token expired'
                refresh_access_token
                exit
              end
            end

          vehicles.each do |vehicle|
            with_rescue(soft_faults, @logger) do |_try|
              @logger.debug vehicle

              if vehicle.state != 'online'
                @logger.info "#{vehicle['display_name']} is #{vehicle.state}, not online"
                next
              end

              charge_state = vehicle.vehicle_data['charge_state']
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
      rescue Faraday::ConnectionFailed, Faraday::ServerError => e
        @logger.info "vehicles for #{account[:username]} are unavailable #{e}"
      end
    end
  end
end

Tesla.start
