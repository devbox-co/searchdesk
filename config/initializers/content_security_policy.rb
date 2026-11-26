Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.style_src :self, :unsafe_inline
    policy.img_src :self, :data
    policy.base_uri :none
    policy.object_src :none
    policy.frame_ancestors :none
  end
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(18) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.action_dispatch.default_headers["Referrer-Policy"] = "strict-origin"
end
