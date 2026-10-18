module MidnightRide
  # One alert about one error: a Telegram message and, within the daily
  # limit, a Claude Code session to fix it.
  #
  # Solid Errors tells errors apart by their whole message, so one with ids
  # in its message is a new error each time. Errors are told apart here
  # without their numbers, and by where in the app they happened.
  #
  # Only the error's class, message and backtrace leave the app, never its
  # context (params and the like): people other than you write those, and
  # the session reads what it's sent.
  class Alert
    # How much of the message and backtrace go out
    MESSAGE_LENGTH = 500
    TELEGRAM_MESSAGE_LENGTH = 300
    BACKTRACE_LINES = 20

    attr_reader :id, :exception_class, :message, :backtrace, :reopened, :still_happening

    # still_happening is how often an unresolved error happened in the last
    # day, for the daily reminder (RemindersJob).
    def initialize id:, exception_class:, message:, backtrace:, reopened: false, still_happening: nil
      @id = id
      @exception_class = exception_class
      @message = message.to_s
      @backtrace = backtrace.to_s
      @reopened = reopened
      @still_happening = still_happening
    end

    def deliver
      # A resolved error that came back, or the daily reminder of one still
      # happening, is worth hearing about again. Neither comes more than once
      # a day, so they aren't checked against what was seen.
      return if !reopened && !still_happening && seen?

      remember
      session_url = start_session if session_allowed?
      self.class.send_telegram(telegram_text(session_url))
    end

    def self.send_telegram text
      token, chat_id = MidnightRide.credentials&.values_at(:telegram_bot_token, :telegram_chat_id)
      unless token && chat_id
        # Otherwise nothing would show that alerts go nowhere.
        MidnightRide.logger.warn("MidnightRide: no telegram_bot_token or telegram_chat_id in the credentials")
        return
      end

      response = post("https://api.telegram.org/bot#{token}/sendMessage", chat_id:, text:, parse_mode: "HTML")
      raise "Telegram answered #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
    end

    # Returns the session's address, or nil without a routine. Each request
    # starts a session, so it's never retried.
    # See https://platform.claude.com/docs/en/api/claude-code/routines-fire
    def self.start_session text
      url, token = MidnightRide.credentials&.values_at(:routine_url, :routine_token)
      unless url && token
        MidnightRide.logger.warn("MidnightRide: no routine_url or routine_token in the credentials")
        return
      end

      response = post(url, {text:}, "Authorization" => "Bearer #{token}", "anthropic-version" => "2023-06-01")
      raise "The routine answered #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["claude_code_session_url"]
    end

    def self.post url, body, headers = {}
      Net::HTTP.post(URI(url), body.to_json, {"Content-Type" => "application/json"}.merge(headers))
    end

    private

    def key
      @key ||= "midnight_ride/#{Digest::SHA256.hexdigest([exception_class, without_numbers(message), without_numbers(location)].join("\n"))}"
    end

    def seen?
      MidnightRide.cache.exist?(key)
    end

    def remember
      MidnightRide.cache.write(key, true, expires_in: MidnightRide.remembered_for)
    end

    # Telegram hears of it if the routine fails. Reporting it would make
    # another error to alert about.
    def start_session
      self.class.start_session(session_text)
    rescue => e
      @session_failure = e.message
      nil
    end

    def session_allowed?
      sessions = MidnightRide.cache.increment("midnight_ride/sessions/#{Date.current}", 1, expires_in: 2.days)
      @limit_reached = sessions > MidnightRide.sessions_per_day
      !@limit_reached
    end

    # The first line of the backtrace in the app's own code
    def location
      backtrace.lines.find { it.start_with?(MidnightRide.root) }.to_s
    end

    def without_numbers text
      text.gsub(/\h*\d\h*/, "#")
    end

    def url
      "#{MidnightRide.dashboard_url}#{id}" if MidnightRide.dashboard_url
    end

    # Dokku sets GIT_REV to the commit it deployed, so the session can tell
    # when it isn't on GitHub yet, rather than look for the error in other
    # code.
    def deployed_commit
      ENV["GIT_REV"].presence || "unknown"
    end

    def headline
      if still_happening
        "an unresolved error is still happening, #{still_happening} #{"time".pluralize(still_happening)} in the last day"
      elsif reopened
        "a resolved error came back"
      else
        "a new error"
      end
    end

    def summary length
      "#{exception_class}: #{message.truncate(length)}"
    end

    def session_text
      <<~TEXT
        App: #{MidnightRide.app_name}
        Repository: #{MidnightRide.repository}
        Deployed commit: #{deployed_commit}
        Error id: #{id}

        #{headline.upcase_first} in production#{" (#{url})" if url}:

        #{summary(MESSAGE_LENGTH)}

        #{backtrace.lines.first(BACKTRACE_LINES).join.gsub(MidnightRide.root + "/", "")}
      TEXT
    end

    def telegram_text session_url
      lines = [
        "<b>#{ERB::Util.h(MidnightRide.app_name)}: #{headline}</b>",
        ERB::Util.h(summary(TELEGRAM_MESSAGE_LENGTH)),
        url
      ]
      lines << if session_url
        "Claude is on it: #{session_url}"
      elsif @session_failure
        "No session started: #{ERB::Util.h(@session_failure.truncate(TELEGRAM_MESSAGE_LENGTH))}"
      elsif @limit_reached
        "No session started: the limit of #{MidnightRide.sessions_per_day} a day is reached."
      end
      lines.compact.join("\n\n")
    end
  end
end
