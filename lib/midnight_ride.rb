require "active_support"
require "active_support/core_ext"
require "digest"
require "erb"
require "json"
require "net/http"

require "midnight_ride/version"

# Alerts you when a Rails app errors in production, on Telegram, and starts
# a Claude Code session to fix the error, through a routine's API trigger.
# It builds on Solid Errors: it speaks up for an error it hasn't seen, a
# resolved one that came back, and, once a day, an unresolved one still
# happening. See the README.
module MidnightRide
  class << self
    # Named in each alert, since the chat and the routine take errors from
    # several apps
    attr_accessor :app_name, :repository
    # Where an error's page is, with its id appended, like
    # "https://example.com/errors/"
    attr_accessor :dashboard_url
    # Each session draws on the subscription, and a storm of new errors
    # shouldn't use it up.
    attr_accessor :sessions_per_day
    # How long an error is remembered, so the same one isn't alerted about
    # again under other numbers
    attr_accessor :remembered_for
    # How long an unresolved error has to stay away to resolve itself
    attr_accessor :quiet_for

    attr_writer :enabled, :credentials, :cache, :logger, :root

    def configure
      yield self
    end

    # In production only, unless set
    def enabled?
      @enabled.nil? ? Rails.env.production? : @enabled
    end

    # telegram_bot_token, telegram_chat_id, routine_url and routine_token,
    # by default from the credentials' midnight_ride block. A proc is called
    # each time, so credentials can change without a restart.
    def credentials
      @credentials.respond_to?(:call) ? @credentials.call : @credentials
    end

    def cache
      @cache || Rails.cache
    end

    def logger
      @logger || Rails.logger
    end

    def root
      (@root || Rails.root).to_s
    end

    # Resolves the Solid Errors errors with the given ids, so they alert
    # again if they come back. For the server's deploys, which resolve the
    # errors the deployed commits name (see the README).
    def resolve ids
      SolidErrors::Error.unresolved.where(id: ids).update_all(resolved_at: Time.current)
    end
  end

  self.sessions_per_day = 5
  self.remembered_for = 1.week
  self.quiet_for = 1.week
  self.credentials = -> { Rails.application.credentials.midnight_ride }
end

require "midnight_ride/alert"
require "midnight_ride/railtie" if defined?(Rails::Railtie)
