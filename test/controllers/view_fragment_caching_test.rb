# frozen_string_literal: true

require "test_helper"

# Phase 0 capacity — fragment caching of the heavy, form-free card bodies
# (track SVG + metrics). The test environment runs with caching off, so
# these tests switch it on against an isolated memory store and restore the
# previous configuration afterwards.
class ViewFragmentCachingTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(valid_user_attributes)
    sign_in @user
    @route = @user.routes.create!(source: "upload", title: "Cached ridge", duration: 1_800)

    @previous_caching = ActionController::Base.perform_caching
    @previous_store = ActionController::Base.cache_store
    ActionController::Base.perform_caching = true
    ActionController::Base.cache_store = ActiveSupport::Cache::MemoryStore.new

    @cache_hits = []
    @subscriber = ActiveSupport::Notifications.subscribe("cache_read.active_support") do |*, payload|
      @cache_hits << payload[:key].to_s if payload[:hit]
    end
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    ActionController::Base.perform_caching = @previous_caching
    ActionController::Base.cache_store = @previous_store
  end

  test "calendar sidebar serves cached card bodies on repeat renders" do
    get calendar_url
    assert_response :success
    assert_empty sidebar_body_hits, "cold render must only write fragments"

    get calendar_url
    assert_response :success
    assert_not_empty sidebar_body_hits, "second render must hit the cached sidebar bodies"
    assert_match "Cached ridge", response.body
    assert_match "wc-route-card__metrics", response.body # cached body markup intact
  end

  test "a route edit invalidates its cached card bodies" do
    get calendar_url
    assert_response :success

    # tier feeds the cached body (sidebar + mobile card), not the uncached head
    @route.update!(tier: "Hard")

    get calendar_url
    assert_response :success
    assert_match "Hard", response.body # versioned cache key: no staleness
    assert_no_match "Unrated", response.body
  end

  test "routes library serves cached card fragments on repeat renders" do
    get routes_url
    assert_response :success

    get routes_url
    assert_response :success
    assert_not_empty library_card_hits, "second library render must hit cached card fragments"
    assert_match "Cached ridge", response.body
  end

  private

  def sidebar_body_hits
    @cache_hits.select { |key| key.include?("wc-sidebar-body") }
  end

  def library_card_hits
    @cache_hits.select { |key| key.match?(/route-card-thumb|route-card-body/) }
  end
end
