require "net/http"
require "timeout"
require "zlib"

module LocalFalcon
  class StreetMapImage
    RETRY_DELAY = 30.seconds
    MAX_BYTES = 8.megabytes
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b

    def self.fetch(snapshot)
      return unless snapshot.provider == "Local Falcon"
      url = ScanGrid.new(snapshot).street_map_url
      return unless url

      image = LocalFalconStreetMap.find_or_create_by!(source_snapshot: snapshot) { |row| row.report_key = snapshot.external_id }
      return image.png if image.report_key == snapshot.external_id && image.png
      image.with_lock do
        if image.report_key != snapshot.external_id
          image.assign_attributes(report_key: snapshot.external_id, png: nil, retry_after: nil)
        end
        next image.png if image.png
        next if image.retry_after&.future?

        bytes = download(URI(url))
        if bytes && !valid_png?(bytes)
          Rails.logger.warn("Local Falcon street map rejected an invalid PNG for snapshot #{snapshot.id}")
          bytes = nil
        end
        image.update!(png: bytes, retry_after: bytes ? nil : RETRY_DELAY.from_now)
        bytes
      end
    end

    def self.download(uri)
      # ScanGrid builds this URL from a fixed origin and a validated report key.
      # The provider serves completed reports anonymously. Never follow redirects.
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 5
      http.read_timeout = 15
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "image/png", "Accept-Encoding" => "identity")
      Timeout.timeout(20) do
        http.request(request) do |response|
          unless response.code == "200" && response.content_type == "image/png"
            Rails.logger.warn("Local Falcon street map returned HTTP #{response.code} or an unexpected content type")
            return
          end
          return if response["Content-Length"].to_i > MAX_BYTES
          bytes = +"".b
          response.read_body do |chunk|
            return if bytes.bytesize + chunk.bytesize > MAX_BYTES
            bytes << chunk
          end
          return bytes
        end
      end
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse => e
      Rails.logger.warn("Local Falcon street map download failed (#{e.class.name})")
      nil
    end
    private_class_method :download

    # Do not permanently cache a truncated or damaged provider response.
    def self.valid_png?(bytes)
      return false unless bytes.start_with?(PNG_SIGNATURE) && bytes.byteslice(8, 8) == "\0\0\0\rIHDR".b
      width, height = bytes.byteslice(16, 8).to_s.unpack("N2")
      return false unless (1..8192).cover?(width) && (1..8192).cover?(height)

      offset = PNG_SIGNATURE.bytesize
      has_pixels = false
      while offset + 12 <= bytes.bytesize
        length = bytes.unpack1("N", offset: offset)
        break if offset + 12 + length > bytes.bytesize
        chunk = bytes.byteslice(offset + 4, length + 4)
        checksum = bytes.unpack1("N", offset: offset + 8 + length)
        return false unless Zlib.crc32(chunk) == checksum
        offset += length + 12
        has_pixels ||= chunk.start_with?("IDAT") && length.positive?
        return has_pixels && offset == bytes.bytesize if chunk == "IEND"
      end
      false
    end
    private_class_method :valid_png?
  end
end
