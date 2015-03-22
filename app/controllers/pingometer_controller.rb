class PingometerController < ApplicationController
  skip_before_action :verify_authenticity_token

  def webhook
    monitor = PingometerMonitor.find_or_create_by! pingometer_id: webhook_params[:monitor_id]
    open_incident = monitor.open_incident

    # refresh the Monitor data, which holds the data for last_event
    monitor.fetch

    event_data = monitor.last_event_data
    timestamp = DateTime.parse event_data['utc_timestamp']

    if webhook_params[:monitor_status] == '0'
      unless open_incident
        open_incident = monitor.incidents.create! started_at: timestamp
      end

      event = open_incident.pingometer_events.create! status: 'down',
        triggered_at: timestamp
      ScreenshotEvent.enqueue event.id

    elsif webhook_params[:monitor_status] == '1'
      if open_incident
        event = open_incident.pingometer_events.create! status: 'up',
          triggered_at: timestamp
        ScreenshotEvent.enqueue event.id

        open_incident.update! finished_at: timestamp
      end
    end

    render json: { '200' => 'Ok' }
  end

  private

  def webhook_params
    params.permit :monitor_id, :monitor_status
  end
end
