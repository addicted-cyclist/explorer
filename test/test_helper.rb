ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # The suite is small, so run it in a single process against the shared
    # explorer_test database instead of fanning out per-worker databases.
    parallelize(workers: 1)

    # Attributes for a User that passes Devise's validatable module plus the
    # app's own first_name/last_name/username validations.
    def valid_user_attributes(email: "rider@example.com")
      {
        email: email,
        password: "password123",
        first_name: "Riley",
        last_name: "Rider",
        username: email.delete("@.").tr(".", "_")
      }
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
  end
end

module ActionDispatch
  class IntegrationTest
    # Devise sign-in helpers for controller tests.
    include Devise::Test::IntegrationHelpers
  end
end
