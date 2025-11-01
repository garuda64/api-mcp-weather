class GetUtcTimeTool
  def call
    Time.now.utc.iso8601
  end
end