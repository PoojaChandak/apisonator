module ThreeScale
  module Backend
    module Alerts
      extend self

      ALERT_TTL       = 24*3600 # 1 day (only one message per day)
      ## zero must be here and sorted, yes or yes
      ALERT_BINS      = [0, 50, 80, 90, 100, 120, 150, 200, 300].freeze
      FIRST_ALERT_BIN = ALERT_BINS.first
      RALERT_BINS     = ALERT_BINS.reverse.freeze

      def utilization(app_usage_reports, user_usage_reports)
        max_utilization = -1.0
        max_record = nil
        max = proc do |item|
          if item.max_value > 0
            utilization = item.current_value / item.max_value.to_f

            if utilization > max_utilization
              max_record = item
              max_utilization = utilization
            end
          end
        end

        app_usage_reports.each(&max)
        user_usage_reports.each(&max)

        if max_utilization == -1
          ## case that all the limits have max_value==0
          max_utilization = 0
          max_record = app_usage_reports.first || user_usage_reports.first
        end

        [max_utilization, max_record]
      end

      def update_utilization(service_id, app_id, max_utilization, max_record, timestamp)
        discrete = utilization_discrete(max_utilization)
        max_utilization_i = (max_utilization * 100.0).round

        beginning_of_day = Period::Boundary.day_start(timestamp)
        period_day = beginning_of_day.to_compact_s
        period_hour = Period::Boundary.hour_start(timestamp).to_compact_s
        # UNIX timestamp for key expiration - add 1 day + 5 mins
        expire_at = (beginning_of_day + 86700).to_i

        alerts_service_app = build_key(service_id, app_id)
        alerts_service = build_key(service_id)

        key = "#{alerts_service_app}#{period_day}/#{discrete}"
        key_notified = "#{alerts_service_app}#{discrete}/already_notified"
        key_allowed = "#{alerts_service}allowed_set"
        key_current_max = "#{alerts_service_app}#{period_hour}/current_max"
        key_last_time_period = "#{alerts_service_app}last_time_period"
        key_stats_utilization = "#{alerts_service_app}stats_utilization"

        ## key_notified does not have the period, it reacts to (service_id/app_id/discrete)
        _, already_alerted, allowed, current_max, last_time_period, _, _ = storage.pipelined do
          storage.incrby(key,"1")
          storage.get(key_notified)
          storage.sismember(key_allowed,discrete)
          storage.get(key_current_max)
          storage.get(key_last_time_period)
          storage.expireat(key, expire_at)
          storage.expireat(key_current_max, expire_at)
        end

        ## update the status of utilization
        if (max_utilization_i > current_max.to_i)

          if (current_max.to_i == 0) && period_hour!=last_time_period
            ## the first one of the hour and not itself. This is only done once per hour

            if !last_time_period.nil?
              value = storage.get("#{alerts_service_app}#{last_time_period}/current_max")
              value = value.to_i
              if value > 0
                storage.pipelined do
                  storage.rpush(key_stats_utilization, "#{Time.parse_to_utc(last_time_period)},#{value}")
                  storage.ltrim(key_stats_utilization, 0, 24*7 - 1)
                end
              end
            end
          end

          storage.pipelined do
            storage.set(key_current_max,max_utilization_i)
            storage.set(key_last_time_period,period_hour)
          end
        end

        if already_alerted.nil? && allowed && discrete.to_i > 0
          next_id, _, _ = storage.pipelined do
            storage.incrby("alerts/current_id",1)
            storage.set(key_notified,"1")
            storage.expire(key_notified,ALERT_TTL)
          end

          alert = { :id => next_id,
                    :utilization => discrete,
                    :max_utilization => max_utilization,
                    :application_id => app_id,
                    :service_id => service_id,
                    :timestamp => timestamp,
                    :limit => "#{max_record.metric_name} per #{max_record.period}: #{max_record.current_value}/#{max_record.max_value}"}

          Backend::EventStorage::store(:alert, alert)
        end
      end

      def utilization_discrete(utilization)
        u = utilization * 100.0
        # reverse search
        RALERT_BINS.find do |b|
          u >= b
        end || FIRST_ALERT_BIN
      end

      def storage
        Storage.instance
      end

      private

      def build_key(service_id, app_id = nil)
        key = "alerts/service_id:#{service_id}/"
        key << "app_id:#{app_id}/" if app_id
        key
      end

    end
  end
end
