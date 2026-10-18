require "test_helper"

class AlertTest < Minitest::Test
  ROOT = "/app"
  BACKTRACE = [
    "#{ROOT}/app/models/idea.rb:42:in 'Idea#tree'",
    "/gems/actionpack/lib/action_controller/metal.rb:10:in 'dispatch'"
  ].join("\n")

  def setup
    MidnightRide.configure do |config|
      config.app_name = "Example"
      config.repository = "user/repo"
      config.dashboard_url = "https://example.com/errors/"
      config.cache = ActiveSupport::Cache::MemoryStore.new
      config.logger = Logger.new(@log = StringIO.new)
      config.root = ROOT
      config.credentials = {}
    end

    # The stubs run on Alert, so they hold on to the lists themselves.
    messages = @messages = []
    sessions = @sessions = []
    stub(:send_telegram) { |text| messages << text }
    stub(:start_session) { |text| sessions << text; "https://claude.ai/code/session_1" }
  end

  ORIGINALS = %i[send_telegram start_session post].to_h { [it, MidnightRide::Alert.method(it)] }

  def teardown
    ORIGINALS.each_key { restore(it) }
  end

  def test_a_new_error_is_sent_to_telegram_and_starts_a_session
    alert(id: 7, message: "undefined method 'name' for nil").deliver

    assert_equal 1, @sessions.size
    assert_includes @sessions.first, "NoMethodError: undefined method 'name' for nil"
    assert_includes @sessions.first, "app/models/idea.rb:42"
    assert_includes @sessions.first, "https://example.com/errors/7"
    assert_includes @sessions.first, "Repository: user/repo"
    assert_includes @sessions.first, "Error id: 7"

    assert_equal 1, @messages.size
    assert_includes @messages.first, "Example: a new error"
    assert_includes @messages.first, "NoMethodError"
    assert_includes @messages.first, "https://example.com/errors/7"
    assert_includes @messages.first, "https://claude.ai/code/session_1"
  end

  def test_the_session_is_told_which_commit_is_deployed
    original = ENV["GIT_REV"]
    ENV["GIT_REV"] = "abc123"

    alert(message: "oops").deliver

    assert_includes @sessions.first, "Deployed commit: abc123"
  ensure
    ENV["GIT_REV"] = original
  end

  def test_telegram_gets_the_message_escaped
    alert(message: 'expected <b> & got "c"').deliver

    assert_includes @messages.first, "expected &lt;b&gt; &amp; got"
  end

  def test_an_error_like_one_alerted_about_but_for_other_numbers_is_left_alone
    alert(id: 1, message: "Couldn't find Idea with 'id'=123").deliver
    alert(id: 2, message: "Couldn't find Idea with 'id'=456").deliver

    assert_equal 1, @sessions.size
    assert_equal 1, @messages.size
  end

  def test_an_error_from_somewhere_else_in_the_code_is_alerted_about
    alert(id: 1, message: "oops").deliver
    alert(id: 2, message: "oops", backtrace: "#{ROOT}/app/models/user.rb:3:in 'User#name'").deliver

    assert_equal 2, @sessions.size
  end

  def test_a_resolved_error_that_comes_back_is_alerted_about_again
    alert(id: 1, message: "oops").deliver
    alert(id: 1, message: "oops", reopened: true).deliver

    assert_equal 2, @sessions.size
    assert_includes @messages.last, "came back"
  end

  def test_an_unresolved_error_still_happening_is_alerted_about_again_with_how_often
    alert(id: 1, message: "oops").deliver
    alert(id: 1, message: "oops", still_happening: 340).deliver

    assert_equal 2, @sessions.size
    assert_includes @sessions.last, "still happening, 340 times in the last day"
    assert_includes @messages.last, "still happening, 340 times in the last day"
  end

  def test_past_the_daily_limit_only_telegram_hears_of_new_errors
    MidnightRide.sessions_per_day.times { |i| alert(id: i, message: "error #{"x" * i}").deliver }
    alert(id: 99, message: "one too many").deliver

    assert_equal MidnightRide.sessions_per_day, @sessions.size
    assert_includes @messages.last, "one too many"
    assert_includes @messages.last, "limit"
  end

  def test_without_a_routine_only_telegram_hears_of_it
    stub(:start_session) { nil }

    alert(message: "oops").deliver

    assert_equal 1, @messages.size
    refute_includes @messages.first, "claude.ai"
  end

  def test_if_the_routine_fails_telegram_hears_why
    stub(:start_session) { |_| raise "The routine answered 429: slow down" }

    alert(message: "oops").deliver

    assert_includes @messages.first, "The routine answered 429"
  end

  def test_a_long_message_is_cut_short
    alert(message: "x" * 5_000).deliver

    assert_operator @sessions.first.size, :<, 2_000
    assert_operator @messages.first.size, :<, 1_000
  end

  def test_without_a_dashboard_alerts_leave_out_the_link
    MidnightRide.dashboard_url = nil

    alert(id: 7, message: "oops").deliver

    refute_includes @messages.first, "/errors/"
    assert_includes @sessions.first, "A new error in production:"
  end

  def test_telegram_messages_go_to_the_chat_as_html
    restore(:send_telegram)
    MidnightRide.credentials = {telegram_bot_token: "token", telegram_chat_id: 1}
    posts = []
    stub(:post) { |url, body| posts << [url, body]; Net::HTTPOK.new("1.1", "200", "OK") }

    MidnightRide::Alert.send_telegram("<b>Hi</b>")

    assert_equal [["https://api.telegram.org/bottoken/sendMessage", {chat_id: 1, text: "<b>Hi</b>", parse_mode: "HTML"}]], posts
  end

  def test_sessions_are_started_through_the_routine
    restore(:start_session)
    MidnightRide.credentials = {routine_url: "https://api.anthropic.com/fire", routine_token: "token"}
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, {claude_code_session_url: "https://claude.ai/code/session_2"}.to_json)
    headers = nil
    stub(:post) { |url, body, h| headers = h; response }

    assert_equal "https://claude.ai/code/session_2", MidnightRide::Alert.start_session("text")
    assert_equal({"Authorization" => "Bearer token", "anthropic-version" => "2023-06-01"}, headers)
  end

  def test_without_credentials_it_says_so_in_the_log
    restore(:send_telegram)
    restore(:start_session)

    MidnightRide::Alert.send_telegram("hi")
    MidnightRide::Alert.start_session("hi")

    assert_includes @log.string, "no telegram_bot_token"
    assert_includes @log.string, "no routine_url"
  end

  private

  def alert id: 1, exception_class: "NoMethodError", message:, backtrace: BACKTRACE, reopened: false, still_happening: nil
    MidnightRide::Alert.new(id:, exception_class:, message:, backtrace:, reopened:, still_happening:)
  end

  def stub name, &block
    MidnightRide::Alert.define_singleton_method(name, &block)
  end

  # Puts back the real method, after setup stubbed it
  def restore name
    MidnightRide::Alert.define_singleton_method(name, ORIGINALS[name])
  end
end
