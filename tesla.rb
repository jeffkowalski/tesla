#!/usr/bin/env ruby
# frozen_string_literal:true

require 'bundler/setup'
Bundler.require(:default)

# See https://developer.tesla.com/docs/fleet-api/getting-started/what-is-fleet-api

class Tesla < RecorderBotBase
  class TimeoutError < StandardError
  end

  desc 'register', 'register application'
  def register
    setup_logger
    @logger.info 'registering application'
    credentials = load_credentials
    audience = 'https://fleet-api.prd.na.vn.cloud.tesla.com'

    # Generate a partner authentication token
    uri = URI('https://auth.tesla.com/oauth2/v3/token')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'

    request.set_form_data(
      'grant_type' => 'client_credentials',
      'client_id' => credentials[:client_id],
      'client_secret' => credentials[:client_secret],
      'scope' => 'openid vehicle_device_data vehicle_cmds vehicle_charging_cmds',
      'audience' => audience
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    auth_response = JSON.parse(response.body)
    partner_token = auth_response['access_token']

    if partner_token.nil?
      @logger.error 'failed to retrieve access token'
      exit(1)
    end

    @logger.debug "partner token: #{partner_token}"
    credentials[:partner_token] = partner_token
    store_credentials credentials

    # Call the Register Endpoint

    uri = URI('https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/partner_accounts')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request['Authorization'] = "Bearer #{partner_token}"
    request.body = JSON.dump({ 'domain' => credentials[:domain]})

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    @logger.info response.read_body
  end

  desc 'authorize', 'authorize a user'
  def authorize
    setup_logger
    @logger.info 'authorizing user'
    credentials = load_credentials
    audience = 'https://fleet-api.prd.na.vn.cloud.tesla.com'

    #
    # See Third party tokens
    # https://developer.tesla.com/docs/fleet-api/authentication/third-party-tokens
    #

    # User authorization
    callback = "https://#{credentials[:domain]}/path"
    state    = Time.now
    auth_url = "https://auth.tesla.com/oauth2/v3/authorize?&client_id=#{credentials[:client_id]}&locale=en-US&prompt=login&redirect_uri=#{URI.encode_www_form_component(callback)}&response_type=code&scope=openid%20vehicle_device_data%20offline_access&state=#{state}"
    puts 'Log in here:', auth_url
    puts 'Then paste the URL where the browser is redirected:'
    url = $stdin.gets.chomp
    code = url[/code=([^&#]+)/, 1]

    # Generate auth code using code exchange
    uri = URI('https://auth.tesla.com/oauth2/v3/token')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/x-www-form-urlencoded'
    request['Authorization'] = "Bearer #{credentials[:partner_token]}"

    request.set_form_data(
      'grant_type' => 'authorization_code',
      'client_id' => credentials[:client_id],
      'client_secret' => credentials[:client_secret],
      'scope' => 'openid vehicle_device_data vehicle_cmds vehicle_charging_cmds',
      'audience' => audience,
      'code' => code,
      'redirect_uri' => callback
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    # Extract access_token and refresh_token from this response
    @logger.debug response.body
    auth_response = JSON.parse(response.body)
    credentials[:access_token] = auth_response['access_token']
    credentials[:refresh_token] = auth_response['refresh_token']
    store_credentials
  end

  desc 'refresh-access-token', 'refresh access token'
  def refresh_access_token
    @logger.info 'refreshing access token'
    credentials = load_credentials

    uri = URI('https://auth.tesla.com/oauth2/v3/token')
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'Content-Type: application/x-www-form-urlencoded'
    request.set_form_data(
      'grant_type' => 'refresh_token',
      'client_id' => credentials[:client_id],
      'refresh_token' => credentials[:refresh_token]
    )

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    @logger.debug response.read_body
    json = JSON.parse(response.body)
    credentials[:access_token] = json['access_token']
    credentials[:refresh_token] = json['refresh_token']
    store_credentials credentials
  end

  no_commands do
    def main
      credentials = load_credentials

      influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('tesla', time_precision: 'ms')

      soft_faults = [Net::OpenTimeout]

      uri = URI('https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/vehicles')
      request = Net::HTTP::Get.new(uri)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{credentials[:access_token]}"

      response = with_rescue(soft_faults, @logger) do |_try|
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
          http.request(request)
        end
      end

      @logger.debug response.read_body
      json = JSON.parse(response.body)
      if json['error']
        refresh_access_token
        exit
      end

      vins = json['response'].collect { |vehicle| vehicle['vin'] }
      @logger.info "querying #{vins}"
      vins.each do |vin|
        # First, query vehicle state, which is inexpensive
        uri = URI("https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/vehicles/#{vin}")
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{credentials[:access_token]}"

        response = with_rescue(soft_faults, @logger) do |_try|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        json = JSON.parse(response.body)
        if json['error']
          @logger.warn "vehicle #{vehicle['vin']} unavailable: #{json['error']}"
          next
        end

        vehicle = json['response']
        if vehicle['state'] != 'online'
          @logger.warn "vehicle #{vehicle['vin']} is not online"
          next
        end

        # If the vehicle is online, then proceed with getting its data (expensive)
        uri = URI("https://fleet-api.prd.na.vn.cloud.tesla.com/api/1/vehicles/#{vin}/vehicle_data")
        request = Net::HTTP::Get.new(uri)
        request['Content-Type'] = 'application/json'
        request['Authorization'] = "Bearer #{credentials[:access_token]}"

        response = with_rescue(soft_faults, @logger) do |_try|
          Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
            http.request(request)
          end
        end

        json = JSON.parse(response.body)
        if json['error']
          @logger.warn "vehicle #{vehicle['vin']} unavailable: #{json['error']}"
          next
        end

        vehicle = json['response']
        @logger.info "vehicle #{vehicle['vin']} \"#{vehicle['vehicle_state']['vehicle_name']}\" is #{vehicle['state']}"

        charge_state = vehicle['charge_state']
        @logger.info "#{charge_state['charging_state']} " \
                     "with a SOC of #{charge_state['battery_level']}% " \
                     "and an estimated range of #{charge_state['est_battery_range']} miles " \
                     "timestamp #{charge_state['timestamp']}"

        tags = { display_name: vehicle['vehicle_state']['vehicle_name'].tr("'", '_') }
        timestamp = charge_state['timestamp']
        data = [{ series: 'est_battery_range', values: { value: charge_state['est_battery_range'].to_f }, tags: tags, timestamp: timestamp },
                { series: 'state',             values: { value: vehicle['state'] },                       tags: tags, timestamp: timestamp }]
        data.push({ series: 'charging_state',  values: { value: charge_state['charging_state'] },         tags: tags, timestamp: timestamp }) if charge_state['charging_state']

        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

Tesla.start
