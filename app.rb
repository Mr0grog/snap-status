require 'sinatra'
require 'net/https'
require 'uri'
require 'json'

PINGOMETER_USER = ENV['PINGOMETER_USER']
PINGOMETER_PASS = ENV['PINGOMETER_PASS']

get '/' do
  # Get basic info on all monitors.
  uri = URI.parse("https://app.pingometer.com/api/v1.0/monitors/")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  request = Net::HTTP::Get.new(uri.request_uri)
  request.initialize_http_header({"Accept" => "application/json"})
  request.basic_auth(PINGOMETER_USER, PINGOMETER_PASS)
  response = http.request(request)
  
  if response.code == "500"
    @error_message = "Our status monitoring system, Pingometer, appears to be having problems."
    return erb :error
  end
  
  # FIXME: Not even trying to check for errors ha ha yep not production.
  monitors = JSON.parse(response.body)['monitors']
  @down = monitors
    .select {|monitor| monitor['last_event']['type'] == 0}
    .map {|monitor| monitor['name'].partition(' |')[0].downcase}
  
  @state_status = {}
  monitors.each do |monitor|
    # An event type of `-1` means a monitor is paused/non-operating.
    # For now, treat that like there's no monitor at all.
    if monitor['last_event']['type'] == -1
      next
    end
    
    name = monitor['name'].partition(' |')[0].downcase
    # We can have multiple monitors per state (e.g. California).
    # If any are down, we want to count all as down.
    if @state_status[name] != false
      # handle bugginess in pingometer api :(
      # See https://github.com/Mr0grog/snap-status/issues/5
      if monitor['last_event'].instance_of?(String)
        monitor['last_event'] = {'type' => monitor['last_event'].match(/'type':\s*(\d+)/)[1].to_i }
      end
      @state_status[name] = monitor['last_event']['type'] != 0
    end
  end
  
  erb :index
end
