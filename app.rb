require 'sinatra'
require 'net/https'
require 'uri'
require 'json'
require './lib/pingometer.rb'

PINGOMETER_USER = ENV['PINGOMETER_USER']
PINGOMETER_PASS = ENV['PINGOMETER_PASS']

MonitorList = JSON.parse(File.read('public/data/pingometer_monitors.json'))

get '/' do
  # Get basic info on all monitors.
  begin
    monitors = Pingometer.new(PINGOMETER_USER, PINGOMETER_PASS).monitors
  rescue
    @error_message = "Our status monitoring system, Pingometer, appears to be having problems."
    return erb :error
  end
  
  @down = monitors
    .select {|monitor| monitor['last_event']['type'] == 0}
    .map {|monitor| monitor['name'].partition(' |')[0].downcase}
  
  @state_status = {}
  @state_week_uptime = {}
  encounters = Hash.new(0)
  
  monitors.each do |monitor|
    # An event type of `-1` means a monitor is paused/non-operating.
    # For now, treat that like there's no monitor at all.
    if monitor['last_event']['type'] == -1
      next
    end
    
    state = monitor_state(monitor)['state'].downcase
    # We can have multiple monitors per state (e.g. California).
    # If any are down, we want to count all as down.
    if @state_status[state] != false
      @state_status[state] = monitor['last_event']['type'] != 0
    end
    
    total_uptime = ((Date.today - 6)..Date.today).reduce(0) do |sum, date|
      sum + monitor['reports']['raw'][date.strftime('%Y-%m-%d')]['uT']
    end
    week_uptime = total_uptime / 7
    if encounters[state] > 0
      week_uptime = (@state_week_uptime[state] * encounters[state] + week_uptime) / (encounters[state] + 1)
    end
    @state_week_uptime[state] = week_uptime

    encounters[state] += 1
  end
  
  erb :index
end

# Kind of hacky thing to get an ensured hostname
# (transactional tests don't have hostnames, so get the hostname of the URL it first loads).
# Not in Pingometer API class because there's not a real generic solution to this. (Or should it be?)
def monitor_hostname(monitor)
  monitor['hostname'].empty? ? monitor['commands']['1']['get'].match(/^[^\/]+\/\/([^\/]*)/)[1] : monitor['hostname']
end

def monitor_state(monitor)
  MonitorList.find {|monitor_info| monitor_info['hostname'] == monitor_hostname(monitor)}
end
