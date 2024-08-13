
> 注: 本文使用的环境为:
> k3s version v1.29.5+k3s1
> Ingress Nginx controller v1.10.1
> Skywalking 9.7.0-066457b
> skywalking-nginx-lua v0.6.0

&emsp;&emsp;本文假设你已经在ingress-nginx命名空间下安装部署了[Ingress Nginx controller](https://kubernetes.github.io/ingress-nginx/deploy/#quick-start)

### 方案

&emsp;&emsp;在介绍方案之前，我们先了解一下相关的背景知识，用于更好的理解集成方案。

&emsp;&emsp;Ingress Nginx Configmap：Ingress Nginx 的各种配置存放地，可以通过该Configmap配置logformat、所开启的插件等。

&emsp;&emsp;Skywalking Nginx Lua：Skywalking 官方提供的 Lua 版本 lib，提供了一系列的操作，自己可以在Nginx的配置文件中编写Lua脚本，适时创建Span、结束Span，从而把 Nginx 当作Skywalking中的一个服务节点集成进Skywalking。
 
&emsp;&emsp;Ingress Nginx 自定义插件：Lua脚本编写的插件，用于对 Ingress Nginx 做编程，想要使用插件必须要将插件放到 Ingress Controller 容器的 /etc/nginx/lua/plugins/插件名称 目录中，且需要在 Ingress Controller 的configmap中开启它。自定义插件支持以下几个钩子：
```
 a. init_worker: 用于对Nginx Worker做一些初始化。
 b. rewrite: 用于修改请求、更改标头、重定向、丢弃请求、进行身份验证等。
 c. header_filter: 当接收到后端response header 时调用此函数，通常用来记录和修改后端的response header。
 d. body_filter: 这是在收到后端response body 时调用的，一般用来记录response body。
 e. log: 当请求处理完成并将响应传递给客户端时，会调用此函数。
   sw8：SkyWalking 跨进程传播的Header Key，它的格式是 1-TRACEID-SEGMENTID-3-PARENT_SERVICE-PARENT_INSTANCE-PARENT_ENDPOINT-IPPORT（其中TraceID、SpanID等都通过base64进行编码），我们可以通过此Header解析出对应的 TraceID。
```
&emsp;&emsp;了解了上述原理后，我们的方案就显而易见了，就是将 Skywalking Nginx Lua 集成进 Ingress Nginx中，并编写插件，在不同阶段执行相关操作：
```
a. 在 rewrite 阶段生成新Span并解析出TraceID将其放在新Header中（方便access log 打印）
b. 在 body_filter 阶段结束该Span
c. 在log阶段提交对应的数据到Skywalking服务端
d. 修改 Nginx log format，将存储 TraceID 的Header 打印出来
```

## 步骤
#### 1、制作Skywalking等相关库的configmap
&emsp;&emsp;Skywalking Nginx Lua 的核心是它的 lib 目录，里边包含了所有需要用到的函数操作，所以我们需要将该 lib 目录的内容放到 Ingress Nginx 的Pod 中，让我们编写的插件能够调用到它。我们将 lib 的内容写入configmap，然后挂载Volume到Pod中。

&emsp;&emsp;我们先克隆以下仓库至服务器,然后将所有lua平放到同一个目录,为制作configmap做准备
```
# 创建目录
mkdir sk-lua-cm

# 获取lib
git clone https://github.com/apache/skywalking-nginx-lua.git
git clone https://github.com/openresty/lua-tablepool.git

# 复制
cp skywalking-nginx-lua/lib/skywalking/*.lua sk-lua-cm/
cp skywalking-nginx-lua/lib/skywalking/dependencies/*.lua sk-lua-cm/
cp skywalking-nginx-lua/lib/resty/*.lua sk-lua-cm/
cp lua-tablepool/lib/* sk-lua-cm/

# 创建configmap资源对象
kubectl create cm skywalking-nginx-lua-agent --from-file=./sk-lua-cm/ -n ingress-nginx
```

#### 2、编写Ingress Nginx 的插件
&emsp;&emsp;引入了 Skywalking 的 lib 后就可以编写对应的 Ingress Nginx 自定义插件了，代码比较简单，以下是代码详情(命名为main.lua)。
```
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
```

在上述代码中获取了几个环境变量，需要记住，后边需要用到。
```
SKY_SERVICE_NAME：Ingress Nginx 在 Skywalking 中的 Service 名称
SKY_INSTANCE_NAME：Ingress Nginx 实例在 Skywalking 中的实例名称
SKY_OAP_ADDR：Skywalking后端地址
```

编写好插件代码后就可以基于此创建configmap了
```
kubectl create cm skywalking-lua-plug --from-file=main.lua -n ingress-nginx
```

#### 3、挂载相关 Lua 脚本进 Ingress Nginx Controller 的 Pod 中
&emsp;&emsp;修改 Ingress Nginx Controller 的 Deployment 配置，主要修改以下几点：

1.环境变量
```
- name: SKY_OAP_ADDR
  value: http://skywalking-oap.skywalking.svc.cluster.local:12800
- name: SKY_SERVICE_NAME
  value: ingress-nginx
- name: SKY_INSTANCE_NAME
  value: ingress-nginx
```

2.volumes声明
```
- name: sky-nginx-plugin
  configMap:
    name: skywalking-lua-plug
- name: skywalking-nginx-lua-agent
  configMap:
    name: skywalking-nginx-lua-agent
```

3.volumeMounts 声明
```
- mountPath: /etc/nginx/lua/plugins/skywalking/main.lua
  subPath: "main.lua"
  name: sky-nginx-plugin
- mountPath: /etc/nginx/lua/resty/http.lua
  subPath: "http.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/tablepool.lua
  subPath: "tablepool.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/resty/http_headers.lua
  subPath: "http_headers.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/resty/jit-uuid.lua
  subPath: "jit-uuid.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/client.lua
  subPath: "client.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/constants.lua
  subPath: "constants.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/correlation_context.lua
  subPath: "correlation_context.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/dependencies/base64.lua
  subPath: "base64.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/management.lua
  subPath: "management.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/segment.lua
  subPath: "segment.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/segment_ref.lua
  subPath: "segment_ref.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/span.lua
  subPath: "span.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/span_layer.lua
  subPath: "span_layer.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/tracer.lua
  subPath: "tracer.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/tracing_context.lua
  subPath: "tracing_context.lua"
  name: skywalking-nginx-lua-agent
- mountPath: /etc/nginx/lua/skywalking/util.lua
  subPath: "util.lua"
  name: skywalking-nginx-lua-agent
```

#### 4、修改 Ingress Nginx Controller 所使用的configmap配置
```
plugins: "skywalking"
lua-shared-dicts: "tracing_buffer: 100m"
main-snippet: |
  env SKY_SERVICE_NAME;
  env SKY_INSTANCE_NAME;
  env SKY_OAP_ADDR;
log-format-upstream: |
  $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent" $request_length $request_time [$proxy_upstream_name] [$proxy_alternative_upstream_name] $upstream_addr $upstream_response_length $upstream_response_time $upstream_status $request_id $http_trace_id
```
该配置中配置了如下几个信息：
```
plugins：开启skywalking插件
lua-shared-dicts：声明 trace 使用的变量和大小
main-snippet：其中声明了需要使用到的环境变量，切记在插件中使用的环境变量必须放到这里来
log-format-upstream：log 格式，我们在这个里添加了一个 http_trace_id 这个header的打印（上一步解析出来的TraceID）
低版本ingress-nginx-controller中的lua-shared-dicts: "tracing_buffer: 100m"可能需要改成lua-shared-dicts: "tracing_buffer: 100"
```

#### 5、重启 Pod 生效
&emsp;&emsp;把下列的 xxx 换成 Ingress Nginx Controller 的 Pod 名称
```
kubectl delete pod xxxx -n ingress-nginx
```

#### 6、相关下载
[main.lua](./resource/main.lua)
[sk-lua-cm.zip](./resource/sk-lua-cm.zip)

## 参考

是这篇的改进，这篇有个很重要的lua-tablepool没有提到
> https://flashcat.cloud/blog/skywalking-integrate-ingress-nginx/

skywalking-nginx-lua
> https://github.com/apache/skywalking-nginx-lua

lua-tablepool 
> https://github.com/openresty/lua-tablepool

ingress-nginx-controller plugins相关知识
> https://github.com/kubernetes/ingress-nginx/blob/main/rootfs/etc/nginx/lua/plugins/README.md