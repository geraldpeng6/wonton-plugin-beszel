# Beszel

服务器状态：CPU、内存、磁盘、网络和温度，带历史图表。上游项目是
<https://github.com/henrygd/beszel>（MIT），本仓库只是它在云吞里的插件包。

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

## 怎么装的

- Hub（网页和存储）和 Agent（采集）都是上游官方镜像，固定在同一个上游版本。
- 两个容器经 `${WONTON_APP_DATA}/socket` 里的 unix 套接字相连（上游文档“Connecting to a local agent”的做法），
  不开端口。Agent 在宿主网络里，网络和传感器读的是宿主自己的。
- 装好就登记了这台服务器：一次性服务用 Hub 的 API 建系统记录（固定 id）并把 Hub 的公钥交给 Agent，
  打开网页直接落在这台服务器的详情页，不用添加机器，也不用登录应用本身。
- 网关代登录按固定内部地址认人（`用户名@beszel.internal`，只认已有用户，不新建）：地址由不会变的用户名拼出来，
  不看邮箱——在云吞里改了邮箱照样进得去，账号资料里显示的也是这个内部地址。
- 没挂 Docker socket：不看每个容器的资源。插件自己在不在跑看 App 的“应用”页。

## 告警

告警邮件的收件人在 Beszel 自己的设置里另填（设置 → 通知，可填多个地址）：上游按通知设置里的地址列表发送，
不读账号邮箱，账号里的内部地址收不到邮件。

## 更新开发套件

```bash
scripts/dev.sh kit-update
```

## 图标

`icon.svg` 是 Beszel 的官方标志（henrygd，MIT），来源、许可全文和商标说明见 [NOTICE](NOTICE)。
