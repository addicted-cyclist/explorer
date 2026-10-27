ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # The suite is small, so run it in a single process against the shared
    # explorer_test database instead of fanning out per-worker databases.
    parallelize(workers: 1)

    # Attributes for a User that passes Devise's validatable module plus the
    # app's own first_name/last_name/username validations. Users default to
    # email-verified so tests exercise their own concern; the
    # verification flow's tests create unverified users explicitly via
    # email_verified_at: nil.
    def valid_user_attributes(email: "rider@example.com", **overrides)
      {
        email: email,
        password: "password123",
        first_name: "Riley",
        last_name: "Rider",
        username: email.delete("@.").tr(".", "_"),
        email_verified_at: Time.current
      }.merge(overrides)
    end

    # An ActiveStorage-attachable handle on a GPX fixture. The on-disk copy is
    # always a short-named fixture (or a temp file for custom content);
    # original_filename: controls the name the controller sees, exactly like a
    # browser would send it.
    def gpx_fixture_upload(filename, content: nil, fixture: "exploration.gpx")
      if content
        dir = Dir.mktmpdir("explorer-test")
        path = File.join(dir, "payload.gpx")
        File.write(path, content)
      else
        path = Rails.root.join("test/fixtures/files", fixture)
      end

      Rack::Test::UploadedFile.new(path.to_s, "application/gpx+xml", false, original_filename: filename)
    end

    # Canned bytes for stubbed Mapbox fetches. Tests never decode the image,
    # so a PNG-magic-prefixed byte string is enough for attach and content
    # type assertions.
    STATIC_MAP_PNG_STUB = ("\x89PNG\r\n\x1a\n".b + "explorer-test-render" * 4).freeze

    # Run the block with Mapbox::StaticImage stubbed so the suite never talks
    # to api.mapbox.com. token: :test presents a token (the service then calls
    # the stubbed fetch); token: false removes it — attachable must return nil
    # without ever fetching, so the stubbed fetch raises as a tripwire.
    # bytes: :stub serves STATIC_MAP_PNG_STUB; any other value is returned
    # verbatim (nil simulates a failed request). Originals are restored.
    def with_mapbox_stubbed(token: :test, bytes: :stub)
      singleton = Mapbox::StaticImage.singleton_class
      singleton.alias_method :__mapbox_orig_token, :access_token
      singleton.alias_method :__mapbox_orig_fetch_png, :fetch_png
      singleton.define_method(:access_token) { token == :test ? "test-token" : nil }
      singleton.define_method(:fetch_png) do |url|
        raise "Mapbox::StaticImage must not fetch without a token (asked for #{url})" if token != :test

        bytes == :stub ? STATIC_MAP_PNG_STUB : bytes
      end
      yield
    ensure
      singleton.alias_method :access_token, :__mapbox_orig_token
      singleton.alias_method :fetch_png, :__mapbox_orig_fetch_png
    end
  end
end

module ActionDispatch
  class IntegrationTest
    # Devise sign-in helpers for controller tests.
    include Devise::Test::IntegrationHelpers
  end
end
