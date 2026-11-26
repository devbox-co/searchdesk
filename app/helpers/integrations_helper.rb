module IntegrationsHelper
  def integration_badge(state)
    tone, icon = case state[:phase]
    when :connected, :linked, :received then ["live", :check]
    when :imported then ["saved", :file_text]
    when :link then ["saved", :external_link]
    when :pending, :ready then ["pending", :calendar]
    when :paused then ["neutral", :minus]
    when :portal then ["neutral", :external_link]
    when :planned then ["neutral", :minus]
    else state[:attention] ? ["attention", :flag] : ["neutral", :info]
    end
    tag.span(class: "badge integration-badge badge-#{tone}") do
      safe_join([ui_icon(icon, size: 14), state[:label]], " ")
    end
  end
end
