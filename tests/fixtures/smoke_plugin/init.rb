# frozen_string_literal: true

Redmine::Plugin.register :smoke_plugin do
  name "Redmine Alpine smoke plugin"
  author "inspired-geek/redmine-alpine"
  description "Cross-version runtime smoke fixture"
  version "1.0.0"
end

class RedmineAlpineSmokePluginHook < Redmine::Hook::ViewListener
  def view_layouts_base_html_head(_context = {})
    stylesheet_link_tag "smoke", plugin: "smoke_plugin"
  end
end
