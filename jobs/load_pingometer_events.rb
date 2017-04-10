class LoadPingometerEvents < Que::Job
  def run(monitor_id=nil)
    monitor_log = monitor_id ? " for #{monitor_id}" : ""
    puts "Loading events from Pingometer#{monitor_log}"

    start_time = Time.now

    @monitor_id = monitor_id
    load_events
    create_incidents

    seconds = Time.now - start_time
    puts "[Job Time] Load pingometer data#{monitor_log} - #{seconds} seconds"
  end

  def client
    @client ||= Pingometer.new(PINGOMETER_USER, PINGOMETER_PASS)
  end

  def monitors
    @monitors ||= @monitor_id ? [client.monitor(@monitor_id)] : client.monitors
  end

  def load_events
    new_events_by_monitor = load_monitor_events
    
    # Create snapshots for any events that were relatively current. We may have
    # imported an event from long ago; snapshotting it now would be inaccurate.
    new_events_by_monitor
      .select do |monitor_id, events|
        events.any? {|event| Time.now - 1.hour < event.date}
      end
      .keys
      .each do |monitor_id|
        SnapshotMonitor.enqueue(monitor_id)
      end
  end

  def load_monitor_events
    puts "  Loading events"

    monitor_states = Hash[monitors.collect do |monitor|
      metadata = monitor_state(monitor)
      abbreviation = metadata ? metadata['state_abbreviation'] : '[UNKNOWN]'
      [monitor['id'], abbreviation]
    end]

    new_events = Hash.new {|hash, key| hash[key] = []}
    client.events(@monitor_id).each do |event|
      monitor_id = event['monitor_id']
      model = MonitorEvent.from_pingometer(
        event,
        monitor_id,
        monitor_states[monitor_id])

      if !MonitorEvent.where(monitor: model.monitor, date: model.date).exists?
        model.accepted = accept_item?(model)
        model.save
        new_events[monitor_id] << model
      end
    end

    new_events
  end

  def accept_item?(item)
    meta = MonitorList.find {|meta| meta["id"] == item.monitor}

    if meta && meta['ignore_dates']
      meta['ignore_dates'].each do |dates|
        start_date = (dates[0] && dates[0].to_time) || Time.new(2000, 1, 1)
        end_date = (dates[1] && dates[1].to_time) || Time.new(3000, 1, 1)
        if item.in_date_range?(start_date, end_date)
          return false
        end
      end
    end

    true
  end

  def create_incidents
    monitors.each &method(:create_monitor_incidents)
  end

  def create_monitor_incidents(monitor)
    puts "  Creating incidents for #{monitor['id']}"

    # Roll through events in date order and create incidents representing consecutive series of down events
    # NOTE: a lot the ifs here are necessary because sometimes we have consecutive up or down events :\
    incident = nil
    MonitorEvent.where(monitor: monitor['id']).each do |event|
      if !event.up?
        # TODO: skip all the everything if we find an existing incident with an end_date
        incident ||= Incident.find_or_initialize_by(monitor: event.monitor, start_date: event.date)
        incident.add_event(event)
      else
        if incident
          incident.add_event(event)
          incident.save
          incident = nil
        end
      end
    end

    # We got to the end with an ongoing incident
    if incident
      incident.save
    end
  end
end
