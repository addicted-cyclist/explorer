# frozen_string_literal: true

require "test_helper"

# Unit tests for the location-chip reverse geocoder (MapsController#place_label
# → Map::ReverseGeocoder): the label is composed from Photon's address
# hierarchy only (never the nearest object's own name), duplicate tiers
# collapse, upstream failures degrade to nil, and results are cached per
# ~1.1 km cell with separate success/failure TTLs so an outage never turns
# every pan into another upstream hit.
class Map::ReverseGeocoderTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:memory_store)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "builds City, Region, Country from the Photon address hierarchy" do
    photon = photon_stub({ city: "Innsbruck", state: "Tirol", country: "Austria" })

    assert_equal "Innsbruck, Tirol, Austria", Map::ReverseGeocoder.label(11.4041, 47.2692, http: photon)
  end

  test "never leaks the nearest object's own name (street or POI hit)" do
    # Real-world Photon answers: the nearest indexed object at the viewport
    # center is often a street or an ATM; its name must not reach the chip.
    photon = photon_stub({ name: "Đường Hồ Thấu", district: "Sơn Trà Ward", city: "Da Nang", country: "Vietnam" })

    assert_equal "Da Nang, Vietnam", Map::ReverseGeocoder.label(108.2552, 16.0817, http: photon)
  end

  test "collapses duplicate tiers (municipality sharing its state's name)" do
    photon = photon_stub({ city: "Da Nang", state: "Da Nang", country: "Vietnam" })

    assert_equal "Da Nang, Vietnam", Map::ReverseGeocoder.label(108.2022, 16.0544, http: photon)
  end

  test "falls down the hierarchy when the city field is absent (rural areas)" do
    photon = photon_stub({ district: "Hòa Vang District", country: "Vietnam" })

    assert_equal "Hòa Vang District, Vietnam", Map::ReverseGeocoder.label(107.9, 15.9, http: photon)
  end

  test "region and country alone are enough (no place in the hierarchy)" do
    photon = photon_stub({ state: "Tirol", country: "Austria" })

    assert_equal "Tirol, Austria", Map::ReverseGeocoder.label(10.9, 47.1, http: photon)
  end

  test "requests the reverse endpoint with lon, lat, lang and a single result" do
    calls = []
    photon = ->(url) { calls << url; JSON.generate({ type: "FeatureCollection", features: [] }) }

    Map::ReverseGeocoder.label(11.4041, 47.2692, http: photon)

    assert_equal 1, calls.size
    assert_includes calls.first, "https://photon.komoot.io/reverse?"
    assert_includes calls.first, "lon=11.4041"
    assert_includes calls.first, "lat=47.2692"
    assert_includes calls.first, "lang=en"
    assert_includes calls.first, "limit=1"
  end

  test "returns nil for an empty feature list or an unparseable payload" do
    empty = ->(_url) { JSON.generate({ type: "FeatureCollection", features: [] }) }
    garbage = ->(_url) { "<html>throttled</html>" }

    assert_nil Map::ReverseGeocoder.label(11.4, 47.26, http: empty)
    assert_nil Map::ReverseGeocoder.label(11.4, 47.27, http: garbage)
  end

  test "returns nil when the upstream call raises (offline, throttled)" do
    failing = ->(_url) { raise Errno::ECONNREFUSED }

    assert_nil Map::ReverseGeocoder.label(11.4, 47.26, http: failing)
  end

  test "caches per rounded cell — a near-identical center does not re-hit Photon" do
    calls = 0
    payload = JSON.generate({ type: "FeatureCollection",
                              features: [ { type: "Feature",
                                            properties: { city: "Da Nang", country: "Vietnam" } } ] })
    photon = ->(_url) { calls += 1; payload }

    first = Map::ReverseGeocoder.label(108.2021, 16.0544, http: photon)
    second = Map::ReverseGeocoder.label(108.2029, 16.0546, http: photon)

    assert_equal "Da Nang, Vietnam", first
    assert_equal first, second
    assert_equal 1, calls
  end

  test "a failed lookup is cached briefly, so an outage does not hit Photon on every pan" do
    calls = 0
    photon = ->(_url) { calls += 1; raise Errno::ECONNREFUSED }

    assert_nil Map::ReverseGeocoder.label(108.2021, 16.0544, http: photon)
    assert_nil Map::ReverseGeocoder.label(108.2021, 16.0544, http: photon)
    assert_equal 1, calls
  end

  private

  def photon_stub(properties)
    payload = { type: "FeatureCollection",
                features: [ { type: "Feature", properties: properties } ] }
    ->(_url) { JSON.generate(payload) }
  end
end
