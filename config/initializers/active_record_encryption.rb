# Derive independent keys from a persistent deployment secret. Retain it with backups.
keys = Rails.application.key_generator
%i[primary_key deterministic_key key_derivation_salt].each do |purpose|
  key = keys.generate_key("searchdesk/record-encryption/v1/#{purpose}", 32)
  Rails.application.config.active_record.encryption.public_send("#{purpose}=", key.unpack1("H*"))
end
Rails.application.config.filter_parameters += %i[phrases authorization payload]
