local _M = {}

function _M.init_worker()
  local metadata_buffer = ngx.shared.tracing_buffer
  require("skywalking.util").set_randomseed()
  local serviceName = os.getenv("SKY_SERVICE_NAME")
  if not serviceName then
    serviceName="ingress-nginx"
  end
  metadata_buffer:set('serviceName', serviceName)

  local serviceInstanceName = os.getenv("SKY_INSTANCE_NAME")
  if not serviceInstanceName then
    serviceName="ingress-nginx"
  end
  metadata_buffer:set('serviceInstanceName', serviceName)
  metadata_buffer:set('includeHostInEntrySpan', false)

  require("skywalking.client"):startBackendTimer(os.getenv("SKY_OAP_ADDR"))
  skywalking_tracer = require("skywalking.tracer")

end


function _M.rewrite()
  local upstreamName = ngx.var.proxy_upstream_name
  skywalking_tracer:start(upstreamName)
  if ngx.var.http_sw8 ~= "" then
    local sw8Str = ngx.var.http_sw8
    local sw8Item = require('skywalking.util').split(sw8Str, "-")
    if #sw8Item >= 2 then
      ngx.req.set_header("trace_id", ngx.decode_base64(sw8Item[2]))
    end
  end
end

function _M.body_filter()

  if ngx.arg[2] then
    skywalking_tracer:finish()
  end

end

function _M.log()
  skywalking_tracer:prepareForReport()
end

return _M
