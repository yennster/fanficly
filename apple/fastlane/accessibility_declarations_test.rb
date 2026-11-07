# frozen_string_literal: true

# ruby fastlane/accessibility_declarations_test.rb (CI runs it in the tooling job)
require "minitest/autorun"
require "tmpdir"
require_relative "accessibility_declarations"

class AccessibilityDeclarationsTest < Minitest::Test
  AD = AccessibilityDeclarations
  ALL_FALSE = AD::FEATURES.to_h { |k| [k, false] }.freeze

  class FakeClient
    attr_reader :calls

    def initialize(pages)
      @pages = pages
      @calls = []
    end

    def get(path, params = nil)
      @calls << [:get, path, params]
      @pages.shift || { "data" => [] }
    end

    def post(path, body, tries: 5)
      @calls << [:post, path, body, tries]
      { "data" => { "id" => "new-#{body[:data][:attributes][:deviceFamily]}" } }
    end

    def patch(path, body)
      @calls << [:patch, path, body]
      { "data" => {} }
    end

    def writes
      @calls.reject { |c| c.first == :get }
    end
  end

  def declaration(id, family, state, features)
    { "id" => id, "attributes" => { "deviceFamily" => family, "state" => state }.merge(features) }
  end

  def wanted(features = ALL_FALSE.merge("supportsVoiceover" => true))
    { "IPHONE" => features }
  end

  def test_the_committed_file_is_valid
    config = AD.load(File.join(__dir__, "accessibility.json"))
    assert_equal AD::FAMILIES, config.keys
    config.each_value { |f| assert_equal AD::FEATURES, f.keys }
  end

  def test_load_rejects_a_missing_feature_or_family
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.json")
      File.write(path, JSON.generate("IPHONE" => ALL_FALSE, "IPAD" => ALL_FALSE))
      assert_raises(ArgumentError) { AD.load(path) }
      features = ALL_FALSE.reject { |k, _| k == "supportsCaptions" }
      File.write(path, JSON.generate(AD::FAMILIES.to_h { |f| [f, features] }))
      assert_raises(ArgumentError) { AD.load(path) }
      File.write(path, JSON.generate(AD::FAMILIES.to_h { |f| [f, ALL_FALSE.merge("supportsCaptions" => "yes")] }))
      assert_raises(ArgumentError) { AD.load(path) }
    end
  end

  def test_creates_and_publishes_when_nothing_exists
    client = FakeClient.new([{ "data" => [] }])
    result = AD.sync(client, "app1", wanted)
    assert_equal [["IPHONE", :published]], result
    post, patch = client.writes
    assert_equal "v1/accessibilityDeclarations", post[1]
    assert_equal 1, post[3]
    assert_equal "IPHONE", post[2][:data][:attributes][:deviceFamily]
    assert_equal({ data: { type: "apps", id: "app1" } }, post[2][:data][:relationships][:app])
    assert_equal "v1/accessibilityDeclarations/new-IPHONE", patch[1]
    assert_equal true, patch[2][:data][:attributes]["publish"]
    assert_equal true, patch[2][:data][:attributes]["supportsVoiceover"]
  end

  def test_leaves_a_matching_published_declaration_alone
    # Never-answered features come back absent, which matches false.
    live = declaration("d1", "IPHONE", "PUBLISHED", "supportsVoiceover" => true)
    client = FakeClient.new([{ "data" => [live] }])
    assert_equal [["IPHONE", :unchanged]], AD.sync(client, "app1", wanted)
    assert_empty client.writes
  end

  def test_publishes_an_existing_draft_instead_of_making_another
    live = declaration("d1", "IPHONE", "PUBLISHED", ALL_FALSE)
    draft = declaration("d2", "IPHONE", "DRAFT", ALL_FALSE)
    other = declaration("d3", "IPAD", "DRAFT", ALL_FALSE)
    client = FakeClient.new([{ "data" => [live, draft, other] }])
    AD.sync(client, "app1", wanted)
    assert_equal [[:patch, "v1/accessibilityDeclarations/d2"]], client.writes.map { |c| c.first(2) }
  end

  def test_dry_run_writes_nothing
    client = FakeClient.new([{ "data" => [] }])
    assert_equal [["IPHONE", :would_publish]], AD.sync(client, "app1", wanted, dry_run: true)
    assert_empty client.writes
  end

  def test_follows_the_next_page
    live = declaration("d1", "IPHONE", "PUBLISHED", "supportsVoiceover" => true)
    client = FakeClient.new([{ "data" => [], "links" => { "next" => "https://next" } }, { "data" => [live] }])
    assert_equal [["IPHONE", :unchanged]], AD.sync(client, "app1", wanted)
    assert_equal "https://next", client.calls[1][1]
  end
end
