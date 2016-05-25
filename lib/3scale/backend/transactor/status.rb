require 'json'

module ThreeScale
  module Backend
    module Transactor
      class Status
        class UsageReport
          def initialize(parent, usage_limit, type)
            @parent      = parent
            @usage_limit = usage_limit
            @type        = type
          end

          def metric_name
            if @type==:application
              @parent.application.metric_name(@usage_limit.metric_id)
            else
              @parent.user.metric_name(@usage_limit.metric_id)
            end
          end

          def period
            @usage_limit.period
          end

          def period_start
            @parent.timestamp.beginning_of_cycle(period)
          end

          def period_end
            @parent.timestamp.end_of_cycle(period)
          end

          def max_value
            @usage_limit.value
          end

          def current_value
            @parent.value_for_usage_limit(@usage_limit,@type)
          end

          def exceeded?
            current_value > max_value
          end

          def inspect
            "#<#{self.class.name} period=#{period}" +
            " metric_name=#{metric_name}" +
            " max_value=#{max_value}" +
            " current_value=#{current_value}>"
          end

          def to_h
            { period: period,
              metric_name: metric_name,
              max_value: max_value,
              current_value: current_value }
          end
        end

        # This is the default field we respond with when using OAuth redirects
        # We only use 'redirect_uri' if a request sent such a param. See #397.
        REDIRECT_URI_FIELD = 'redirect_url'.freeze
        private_constant :REDIRECT_URI_FIELD

        XML_SEPARATOR = '<__separator__/>'.freeze
        private_constant :XML_SEPARATOR

        def initialize(attributes = {})
          @service     = attributes[:service]
          @application = attributes[:application]
          @oauth       = attributes[:oauth]
          @usage       = attributes[:usage]
          @values      = attributes[:values] || {}
          @user        = attributes[:user]
          @user_values = attributes[:user_values]
          @timestamp   = attributes[:timestamp] || Time.now.getutc

          if (@application.nil? and @user.nil?)
            raise ':application is required'
          end

          @redirect_uri_field = REDIRECT_URI_FIELD
          @authorized  = true
        end

        attr_reader :service
        attr_reader :application
        attr_reader :oauth
        attr_accessor :redirect_uri_field
        attr_reader :usage
        attr_accessor :values
        attr_reader :user
        attr_accessor :user_values

        def reject!(error)
          @authorized = false
          @rejection_reason_code ||= error.code
          @rejection_reason_text ||= error.message
        end

        attr_reader :timestamp
        attr_reader :rejection_reason_code
        attr_reader :rejection_reason_text

        def authorized?
          @authorized
        end

        def plan_name
          @application.plan_name unless @application.nil?
        end

        def application_plan_name
           plan_name
        end

        def user_plan_name
          @user.plan_name unless @user.nil?
        end

        def usage_reports
          application_usage_reports
        end

        def application_usage_reports
          @usage_report ||= load_usage_reports @application, :application
        end

        def user_usage_reports
          @user_usage_report ||= load_usage_reports @user, :user
        end


        def value_for_usage_limit(usage_limit, type = :application)
          if type==:application
            values = @values[usage_limit.period]
          else
            values = @user_values[usage_limit.period]
          end
          values && values[usage_limit.metric_id] || 0
        end

        def value_for_application_usage_limit(usage_limit)
          values = @values[usage_limit.period]
          values && values[usage_limit.metric_id] || 0
        end

        def value_for_user_usage_limit(usage_limit)
          values = @user_values[usage_limit.period]
          values && values[usage_limit.metric_id] || 0
        end

        def to_xml(options = {})
          xml = ''
          xml << '<?xml version="1.0" encoding="UTF-8"?>'.freeze unless options[:skip_instruct]
          xml << '<status><authorized>'.freeze

          if authorized?
            xml << 'true</authorized>'.freeze
          else
            xml << 'false</authorized><reason>'.freeze
            xml << rejection_reason_text << '</reason>'.freeze
          end

          if oauth
            redirect_uri = application.redirect_url
            xml << '<application>' \
                   "<id>#{application.id}</id>" \
                   "<key>#{application.keys.first}</key>" \
                   "<#{@redirect_uri_field}>#{redirect_uri}</#{@redirect_uri_field}>" \
                   '</application>'
            if !@user.nil?
              xml << "<user><id>#{@user.username}</id></user>"
            end
          end

          if !@application.nil? && !options[:exclude_application]
            xml << '<plan>'.freeze
            xml << plan_name.to_s.encode(xml: :text) << '</plan>'.freeze
            xml << aux_reports_to_xml(:application, application_usage_reports, options)
          end
          if !@user.nil? && !options[:exclude_user]
            xml << '<user_plan>'.freeze
            xml << user_plan_name.to_s.encode(xml: :text) << '</user_plan>'.freeze
            xml << aux_reports_to_xml(:user, user_usage_reports, options)
          end

          xml << '</status>'.freeze
        end

        private

        def load_usage_reports(what, type)
          return [] if what.nil?
          what.usage_limits.map do |usage_limit|
            UsageReport.new self, usage_limit, type
          end
        end

        def aux_reports_to_xml(report_type, reports, options)
          xml = ''
          unless reports.empty?
            xml_node = if report_type == :application
                         'usage_reports>'.freeze
                       else
                         'user_usage_reports>'.freeze
                       end
            xml << '<'.freeze
            xml << xml_node
            reports.each do |report|
              attributes = "metric=\"#{report.metric_name}\" " \
                           "period=\"#{report.period}\""
              attributes << " exceeded=\"true\"" if report.exceeded?
              xml << "<usage_report #{attributes}>"

              if report.period != :eternity
                xml << '<period_start>' << report.period_start.strftime(TIME_FORMAT) << '</period_start>'
                xml << '<period_end>' << report.period_end.strftime(TIME_FORMAT) << '</period_end>'
              end
              xml << '<max_value>' << report.max_value.to_s << '</max_value><current_value>'

              xml << if authorized? && usage && (usage_metric_name = usage[report.metric_name])
                       # this is a authrep request and therefore we should sum the usage
                       Usage.get_from usage_metric_name, report.current_value
                     else
                       report.current_value
                     end.to_s

              xml << '</current_value></usage_report>'.freeze
            end
            xml << '</'.freeze
            xml << xml_node
          end

          xml
        end
      end
    end
  end
end
