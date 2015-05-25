class LoadPingometerEvents
  def self.perform(monitor_id=nil)
    self.new.perform(monitor_id)
  end

  def perform(monitor_id=nil)
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
    with_new_events = load_monitor_events
    with_new_events.each do |monitor_id|
      Qu.enqueue(SnapshotMonitor, monitor_id)
    end
  end

  def load_monitor_events
    puts "  Loading events"

    monitor_states = Hash[monitors.collect do |monitor|
      [monitor['id'], monitor_state(monitor)['state_abbreviation']]
    end]

    new_events = {}
    client.events(@monitor_id).each do |event|
      monitor_id = event['monitor_id']
      model = MonitorEvent.from_pingometer(
        event,
        monitor_id,
        monitor_states[monitor_id])

      if !MonitorEvent.where(monitor: model.monitor, date: model.date).exists?
        model.accepted = accept_item?(model)
        model.save
        new_events[monitor_id] = true
      end
    end

    new_events.collect {|id, _| id}
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
