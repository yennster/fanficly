# frozen_string_literal: true

require "json"

# The App Store's accessibility declarations ("Accessibility Nutrition
# Labels"): which accessibility features the listing says Fanficly supports on
# each device. fastlane has no action for them, so this talks to the App Store
# Connect API's accessibilityDeclarations resource through any client with
# get/post/patch (Spaceship's in the `accessibility` lane, a fake in
# accessibility_declarations_test.rb).
#
# A declaration is DRAFT, PUBLISHED or REPLACED. Publishing a draft (PATCH
# publish: true) puts it on the live product page straight away, with no App
# Review, and replaces the one that was published.
module AccessibilityDeclarations
  FAMILIES = %w[IPHONE IPAD MAC].freeze
  FEATURES = %w[
    supportsVoiceover supportsVoiceControl supportsLargerText supportsDarkInterface
    supportsDifferentiateWithoutColorAlone supportsSufficientContrast supportsReducedMotion
    supportsCaptions supportsAudioDescriptions
  ].freeze

  module_function

  # fastlane/accessibility.json: every family with every feature, as true or false.
  def load(path)
    config = JSON.parse(File.read(path))
    raise ArgumentError, "#{path}: expected an object" unless config.is_a?(Hash)
    unknown = config.keys - FAMILIES
    raise ArgumentError, "#{path}: unknown device families #{unknown.join(', ')}" unless unknown.empty?
    FAMILIES.to_h do |family|
      features = config[family]
      raise ArgumentError, "#{path}: #{family} is missing" unless features.is_a?(Hash)
      extra = features.keys - FEATURES
      raise ArgumentError, "#{path}: #{family} has unknown keys #{extra.join(', ')}" unless extra.empty?
      FEATURES.each do |key|
        unless [true, false].include?(features[key])
          raise ArgumentError, "#{path}: #{family}.#{key} must be true or false"
        end
      end
      [family, FEATURES.to_h { |key| [key, features[key]] }]
    end
  end

  # Makes App Store Connect's published declarations match `wanted`. Returns
  # one [family, :unchanged | :published | :would_publish] per family.
  # dry_run reads only.
  def sync(client, app_id, wanted, dry_run: false, log: ->(_) {})
    existing = fetch(client, app_id)
    wanted.map do |family, features|
      mine = existing.select { |d| d.dig("attributes", "deviceFamily") == family }
      live = mine.find { |d| d.dig("attributes", "state") == "PUBLISHED" }
      if live && same?(live["attributes"], features)
        log.call("#{family}: already published")
        next [family, :unchanged]
      end
      log.call("#{family}: #{live ? 'change' : 'publish'} to #{describe(features)}")
      next [family, :would_publish] if dry_run

      draft = mine.find { |d| d.dig("attributes", "state") == "DRAFT" } ||
              data(client.post("v1/accessibilityDeclarations", { data: {
                type: "accessibilityDeclarations",
                attributes: { deviceFamily: family }.merge(features),
                relationships: { app: { data: { type: "apps", id: app_id } } }
              } }))
      # A leftover draft gets the wanted answers too, since it's what publishes.
      client.patch("v1/accessibilityDeclarations/#{draft['id']}", { data: {
        type: "accessibilityDeclarations", id: draft["id"],
        attributes: features.merge("publish" => true)
      } })
      [family, :published]
    end
  end

  def fetch(client, app_id)
    found = []
    page = client.get("v1/apps/#{app_id}/accessibilityDeclarations", { limit: 200 })
    while page
      body = page.respond_to?(:body) ? page.body : page
      found.concat(body["data"] || [])
      following = body.dig("links", "next")
      page = following && client.get(following)
    end
    found
  end

  # The API leaves out a feature that was never answered: that reads as false.
  def same?(attributes, features)
    FEATURES.all? { |key| (attributes[key] == true) == features[key] }
  end

  def describe(features)
    on = FEATURES.select { |key| features[key] }.map { |key| key.delete_prefix("supports") }
    on.empty? ? "no features" : on.join(", ")
  end

  def data(response)
    (response.respond_to?(:body) ? response.body : response)["data"]
  end
end
