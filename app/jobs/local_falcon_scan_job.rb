class LocalFalconScanJob < ApplicationJob
  def perform(id, owner_id)
    receipt = SourceSnapshot.find_by(id: id)
    LocalFalcon::ScanCollection.perform(receipt, owner_id) if receipt
  end
end
